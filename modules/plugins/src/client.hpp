#pragma once
#include "model.hpp"
#include <thread>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <atomic>
namespace miucs {
class Client {
  struct Process;
  std::unique_ptr<Process> process;
  std::thread io, watchdog;
  std::mutex mutex;
  std::condition_variable wake;
  std::deque<Json> controls;
  Json pending;
  Scene latest;
  std::string failure;
  std::atomic<bool> stopped{false}, ready{false};
  std::atomic<int64_t> expires{0};
  std::atomic<uint64_t> completed{0};
  void run();
  void fail(const std::string&);
public:
  const std::filesystem::path directory;
  Client(const std::string& worker,const std::string& root);
  ~Client();
  void post(Json);
  void shutdown();
  bool snapshot(Scene&);
  bool isReady()const{return ready;}
  uint64_t completedCount()const{return completed;}
  std::string error();
  void rejectRender(const std::string&);
};
}
