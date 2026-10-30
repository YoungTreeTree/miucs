#include "client.hpp"
#include <cstdio>
#ifdef _WIN32
#include <windows.h>
#else
#include <spawn.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <signal.h>
extern char** environ;
#endif
namespace miucs {
static int64_t nowMs(){return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();}
struct Client::Process {
#ifdef _WIN32
  HANDLE input=nullptr,output=nullptr,child=nullptr;
  Process(const std::string& worker,const std::string& root,uint64_t seed) {
    SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};HANDLE inRead=nullptr,outWrite=nullptr;
    if(!CreatePipe(&inRead,&input,&sa,0))throw Error("Cannot create worker input pipe");
    if(!CreatePipe(&output,&outWrite,&sa,0)){CloseHandle(inRead);CloseHandle(input);input=nullptr;throw Error("Cannot create worker output pipe");}
    SetHandleInformation(input,HANDLE_FLAG_INHERIT,0);SetHandleInformation(output,HANDLE_FLAG_INHERIT,0);
    STARTUPINFOW si{};si.cb=sizeof(si);si.dwFlags=STARTF_USESTDHANDLES;si.hStdInput=inRead;si.hStdOutput=outWrite;si.hStdError=GetStdHandle(STD_ERROR_HANDLE);
    auto exe=std::filesystem::u8path(worker).wstring(),folder=std::filesystem::u8path(root).wstring();
    if(exe.find(L'"')!=exe.npos||folder.find(L'"')!=folder.npos)throw Error("Invalid worker path");
    std::wstring command=L"\""+exe+L"\" \""+folder+L"\" --parent-pid "+std::to_wstring(GetCurrentProcessId())+L" --seed "+std::to_wstring(seed);PROCESS_INFORMATION pi{};
    BOOL ok=CreateProcessW(exe.c_str(),command.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW,nullptr,nullptr,&si,&pi);
    CloseHandle(inRead);CloseHandle(outWrite);if(!ok){CloseHandle(input);CloseHandle(output);input=output=nullptr;throw Error("Cannot start plugin worker");}child=pi.hProcess;CloseHandle(pi.hThread);
  }
  size_t read(void* p,size_t n){DWORD count=0;if(!ReadFile(output,p,DWORD(n),&count,nullptr))return 0;return count;}
  size_t write(const void* p,size_t n){DWORD count=0;if(!WriteFile(input,p,DWORD(n),&count,nullptr))return 0;return count;}
  void kill(){if(child)TerminateProcess(child,1);}
  ~Process(){kill();if(child){WaitForSingleObject(child,1000);CloseHandle(child);}if(input)CloseHandle(input);if(output)CloseHandle(output);}
#else
  int input=-1,output=-1;pid_t child=-1;
  Process(const std::string& worker,const std::string& root,uint64_t seed) {
    int in[2],out[2];if(pipe(in)!=0)throw Error("Cannot create input pipe");
    if(pipe(out)!=0){close(in[0]);close(in[1]);throw Error("Cannot create output pipe");}
    for(int fd:{in[0],in[1],out[0],out[1]})fcntl(fd,F_SETFD,FD_CLOEXEC);
    posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions,in[0],STDIN_FILENO);posix_spawn_file_actions_adddup2(&actions,out[1],STDOUT_FILENO);
    for(int fd:{in[0],in[1],out[0],out[1]})posix_spawn_file_actions_addclose(&actions,fd);
    std::string parent=std::to_string(getpid()),seedText=std::to_string(seed);
    char* args[]={const_cast<char*>(worker.c_str()),const_cast<char*>(root.c_str()),const_cast<char*>("--parent-pid"),parent.data(),const_cast<char*>("--seed"),seedText.data(),nullptr};
    int code=posix_spawn(&child,worker.c_str(),&actions,nullptr,args,environ);posix_spawn_file_actions_destroy(&actions);
    close(in[0]);close(out[1]);if(code){close(in[1]);close(out[0]);throw Error("Cannot start plugin worker");}
    input=in[1];output=out[0];
#ifdef __APPLE__
    int yes=1;fcntl(input,F_SETNOSIGPIPE,yes);
#endif
  }
  size_t read(void* p,size_t n){ssize_t c;do{c=::read(output,p,n);}while(c<0&&errno==EINTR);return c>0?size_t(c):0;}
  size_t write(const void* p,size_t n){ssize_t c;do{c=::write(input,p,n);}while(c<0&&errno==EINTR);return c>0?size_t(c):0;}
  void kill(){if(child>0)::kill(child,SIGKILL);}
  ~Process(){kill();if(child>0)waitpid(child,nullptr,0);if(input>=0)close(input);if(output>=0)close(output);}
#endif
  Json receive(){uint8_t h[4];readAll(h,4);size_t n=h[0]|uint32_t(h[1])<<8|uint32_t(h[2])<<16|uint32_t(h[3])<<24;
    if(n>MaxPacket)throw Error("Worker packet limit exceeded");std::vector<uint8_t>b(n);readAll(b.data(),n);return decode(b.data(),n);}
  void readAll(void* p,size_t n){auto* ptr=static_cast<uint8_t*>(p);while(n){size_t k=read(ptr,n);if(!k)throw Error("Plugin worker disconnected");ptr+=k;n-=k;}}
  void send(const Json& value){auto b=encode(value);uint32_t n=uint32_t(b.size());uint8_t h[]={uint8_t(n),uint8_t(n>>8),uint8_t(n>>16),uint8_t(n>>24)};writeAll(h,4);writeAll(b.data(),b.size());}
  void writeAll(const void* p,size_t n){auto* ptr=static_cast<const uint8_t*>(p);while(n){size_t k=write(ptr,n);if(!k)throw Error("Plugin worker disconnected");ptr+=k;n-=k;}}
};
Client::Client(const std::string& worker,const std::string& root,uint64_t seed):directory(std::filesystem::canonical(std::filesystem::u8path(root))) {
  manifest(directory);process=std::make_unique<Process>(worker,root,seed);expires=nowMs()+1500;
  io=std::thread([this]{run();});
  watchdog=std::thread([this]{while(!stopped){int64_t limit=expires;if(limit&&nowMs()>limit){fail("Plugin worker exceeded deadline");process->kill();break;}std::this_thread::sleep_for(std::chrono::milliseconds(10));}});
}
Client::~Client(){stopped=true;wake.notify_all();process->kill();if(io.joinable())io.join();if(watchdog.joinable())watchdog.join();}
void Client::shutdown(){
  try {post({{"op","dispose"}});}catch(...){return;}
  std::unique_lock lock(mutex);wake.wait_for(lock,std::chrono::milliseconds(550),[this]{return stopped.load();});
}
void Client::fail(const std::string& message){std::lock_guard lock(mutex);failure=message;ready=false;stopped=true;wake.notify_all();}
void Client::rejectRender(const std::string& message){fail(message);process->kill();}
std::string Client::error(){std::lock_guard lock(mutex);return failure;}
Json Client::inspect(){
  std::lock_guard lock(mutex);Json nodes=Json::array();
  for(auto& [id,node]:latest.nodes)nodes.push_back(*node);
  return {{"version",latest.version},{"nodes",std::move(nodes)},{"updateMs",updateMs},{"luaBytes",luaBytes},{"sceneBytes",latest.bytes},{"completed",completed.load()},{"error",failure}};
}
bool Client::snapshot(Scene& into){std::unique_lock lock(mutex,std::try_to_lock);if(!lock||!ready||(into.version==latest.version&&into.revision==latest.revision))return false;into=latest;return true;}
static void mergeEvents(Json& next,const Json& old,const char* source,const char* field,size_t limit) {
  if(!next.contains(source)||!old.contains(source))return;
  auto& n=next[source];auto& o=old[source];if(n.value("sessionID","")!=o.value("sessionID",""))return;
  auto a=o.value(field,Json::array());auto more=n.value(field,Json::array());
  uint64_t last=a.empty()?0:a.back().value("sequence",uint64_t(0));
  for(auto& e:more)if(e.value("sequence",uint64_t(0))>last){a.push_back(e);last=e.value("sequence",uint64_t(0));}
  double now=next.value("now",0.0);size_t lost=0;
  while(!a.empty()&&(a.size()>limit||now-a[0].value("receivedAt",now)>.25)){a.erase(a.begin());++lost;}
  n[field]=std::move(a);
  const char* counter=std::string(source)=="keyboard"?"droppedEventCount":std::string(field)=="beats"?"droppedBeatCount":"droppedOnsetCount";
  n[counter]=n.value(counter,uint64_t(0))+o.value(counter,uint64_t(0))+lost;
}
void Client::post(Json value){
  std::lock_guard lock(mutex);if(stopped)throw Error(failure.empty()?"Plugin stopped":failure);
  if(value.value("op","")=="update") {
    if(!pending.is_null()){
      auto& next=value["value"];auto& old=pending["value"];
      mergeEvents(next,old,"keyboard","events",128);mergeEvents(next,old,"audio","beats",64);mergeEvents(next,old,"audio","onsets",64);
      next["deltaTime"]=next.value("deltaTime",0.0)+old.value("deltaTime",0.0);
      if(next.contains("audio")&&old.contains("audio")&&next["audio"].value("sessionID","")==old["audio"].value("sessionID",""))next["audio"]["spectralFluxPeak"]=std::max(next["audio"].value("spectralFluxPeak",0.0),old["audio"].value("spectralFluxPeak",0.0));
    } pending=std::move(value);
  }else{
    // Preserve input that arrived before a resize/appearance/lifecycle boundary.
    if(controls.size()+(pending.is_null()?1:2)>64)throw Error("Control queue limit exceeded");
    if(!pending.is_null()){controls.push_back(std::move(pending));pending=nullptr;}
    controls.push_back(std::move(value));
  }
  wake.notify_one();
}
void Client::run(){try{
  Scene current;bool disposing=false;
  while(!stopped){
    auto response=process->receive();expires=0;
    if(!response.value("ok",false))throw Error(response.value("error","Plugin failed"));
    const auto& packet=response.at("scene");
    if(!packet.value("full",false) && packet.at("base").get<uint64_t>()!=current.version){
      expires=nowMs()+500;process->send({{"op","sync"}});continue;
    }
    bool changed=current.apply(packet);
    if(disposing){++completed;stopped=true;ready=false;wake.notify_all();break;}
    Json next;
    {std::unique_lock lock(mutex);if(changed)latest=current;updateMs=response.value("updateMs",0.0);luaBytes=response.value("luaBytes",size_t(0));ready=true;++completed;
      wake.wait(lock,[this]{return stopped||!controls.empty()||!pending.is_null();});if(stopped)break;
      if(!controls.empty()){next=std::move(controls.front());controls.pop_front();}else{next=std::move(pending);pending=nullptr;}
    }
    disposing=next.value("op","")=="dispose";next["ack"]=current.version;expires=nowMs()+500;process->send(next);
  }
}catch(const std::exception& e){if(!stopped)fail(e.what());}}
}
