// Reproduce camera interference and restart stalls with libcamera.
// usage: swaptest <camA-substr> <camB-substr> [cycle N [b]]
// GAP_MS=<ms> adds a pause between stop and the next start in cycle mode.
#include <libcamera/libcamera.h>
#include <sys/mman.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <ctime>
#include <memory>
#include <thread>
#include <vector>
using namespace libcamera;
using namespace std::chrono_literals;

struct Cam {
	const char *tag;
	std::shared_ptr<Camera> cam;
	std::unique_ptr<CameraConfiguration> cfg;
	std::unique_ptr<FrameBufferAllocator> alloc;
	std::vector<std::unique_ptr<Request>> reqs;
	std::atomic<int> done{0}, bad{0};
	double lastMean = -1;
	bool started = false;

	void onComplete(Request *r) {
		if (r->status() == Request::RequestCancelled)
			return;
		FrameBuffer *fb = r->buffers().begin()->second;
		if (fb->metadata().status != FrameMetadata::FrameSuccess) bad++;
		else {
			const FrameBuffer::Plane &p = fb->planes()[0];
			void *m = mmap(nullptr, p.length, PROT_READ, MAP_SHARED, p.fd.get(), p.offset);
			if (m != MAP_FAILED) {
				const uint8_t *d = (const uint8_t *)m; double s = 0; size_t n = 0;
				for (size_t i = 0; i < p.length; i += 97) { s += d[i]; n++; }
				lastMean = s / n; munmap(m, p.length);
			}
			done++;
		}
		r->reuse(Request::ReuseBuffers);
		cam->queueRequest(r);
	}
	int configure() {
		cfg = cam->generateConfiguration({ StreamRole::Viewfinder });
		cfg->at(0).size = { 1280, 720 };
		cfg->at(0).pixelFormat = formats::XRGB8888;
		cfg->at(0).bufferCount = 4;
		cfg->validate();
		int ret = cam->configure(cfg.get());
		printf("[%s] configure -> %d (%s)\n", tag, ret, cfg->at(0).toString().c_str());
		return ret;
	}
	int start() {
		Stream *s = cfg->at(0).stream();
		alloc = std::make_unique<FrameBufferAllocator>(cam);
		if (alloc->allocate(s) < 0) { printf("[%s] alloc failed\n", tag); return -1; }
		reqs.clear();
		for (auto &b : alloc->buffers(s)) {
			auto r = cam->createRequest(); r->addBuffer(s, b.get()); reqs.push_back(std::move(r));
		}
		cam->requestCompleted.connect(this, &Cam::onComplete);
		int ret = cam->start();
		printf("[%s] start -> %d\n", tag, ret);
		if (ret) { cam->requestCompleted.disconnect(this); return ret; }
		started = true;
		for (auto &r : reqs) cam->queueRequest(r.get());
		return 0;
	}
	void stop() {
		if (started) cam->stop();
		started = false;
		cam->requestCompleted.disconnect(this);
		reqs.clear(); alloc.reset();
	}
	void report(const char *when) {
		printf("[%s] %s: %d good frames, %d errored, last mean %.1f\n", tag, when, done.load(), bad.load(), lastMean);
		done = 0; bad = 0; lastMean = -1;
	}
};

int main(int argc, char **argv) {
	if (argc < 3) { fprintf(stderr, "usage: %s camA camB\n", argv[0]); return 1; }
	setvbuf(stdout, nullptr, _IOLBF, 0);
	CameraManager cm; cm.start();
	Cam A, B; A.tag = "A"; B.tag = "B";
	for (auto &c : cm.cameras()) {
		if (strstr(c->id().c_str(), argv[1])) A.cam = c;
		if (strstr(c->id().c_str(), argv[2])) B.cam = c;
	}
	if (!A.cam || !B.cam) { fprintf(stderr, "camera not found\n"); return 1; }
	printf("A=%s\nB=%s\n", A.cam->id().c_str(), B.cam->id().c_str());
	A.cam->acquire(); B.cam->acquire();

	if (argc >= 5 && !strcmp(argv[3], "cycle")) {
		/* Restart A alone N times; optionally (argv[5]=="b") start/stop B in between. */
		int n = atoi(argv[4]), stalls = 0;
		bool withB = argc >= 6 && !strcmp(argv[5], "b");
		for (int i = 0; i < n; i++) {
			A.configure();
			if (!A.start()) {
				std::this_thread::sleep_for(1500ms);
				int d = A.done.load();
				struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
				printf("  t=%ld.%03ld cycle %d: %s %d frames\n", ts.tv_sec, ts.tv_nsec / 1000000, i, d < 20 ? "STALL" : "ok", d);
				if (d < 20) stalls++;
				A.report("cycle");
			}
			A.stop();
			if (getenv("GAP_MS")) std::this_thread::sleep_for(std::chrono::milliseconds(atoi(getenv("GAP_MS"))));
			if (withB) { B.configure(); if (!B.start()) { std::this_thread::sleep_for(800ms); B.report("b"); } B.stop(); }
		}
		printf("RESULT: %d stalls in %d starts\n", stalls, n);
		A.cam->release(); B.cam->release(); A.cam.reset(); B.cam.reset(); cm.stop();
		return 0;
	}

	printf("--- scenario 1: configure A, configure B, start A (PipeWire: A paused, B negotiated)\n");
	A.configure(); B.configure();
	if (!A.start()) { std::this_thread::sleep_for(3s); A.report("after 3 s"); }
	A.stop();

	printf("--- scenario 2: A streams, then B is configured and started (overlapping switch)\n");
	A.configure();
	if (!A.start()) {
		std::this_thread::sleep_for(1500ms); A.report("alone, 1.5 s");
		if (!B.configure() && !B.start()) {}
		std::this_thread::sleep_for(3s);
		A.report("with B, 3 s"); B.report("with A, 3 s");
	}
	B.stop(); A.stop();

	printf("--- scenario 3: sequential A then B then A (sanity)\n");
	for (Cam *c : { &A, &B, &A }) {
		c->configure();
		if (!c->start()) { std::this_thread::sleep_for(2s); c->report("2 s"); }
		c->stop();
	}
	A.cam->release(); B.cam->release();
	A.cam.reset(); B.cam.reset();
	cm.stop();
	return 0;
}
