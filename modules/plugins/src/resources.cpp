#include "model.hpp"
#include <array>
#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#endif
namespace miucs {
// Open relative resources through a verified handle. Validation followed by an ordinary
// path-based read would allow a directory/symlink swap between those two operations.
std::string readResource(const std::filesystem::path& root,const std::string& relative,size_t limit) {
  contained(root,relative);
#ifdef _WIN32
  auto base=std::filesystem::canonical(root);
  HANDLE file=CreateFileW((base/std::filesystem::u8path(relative)).c_str(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
  if(file==INVALID_HANDLE_VALUE)throw Error("Cannot open resource");
  struct Close {HANDLE handle;~Close(){CloseHandle(handle);}} guard{file};
  auto finalPath=[](HANDLE handle){DWORD n=GetFinalPathNameByHandleW(handle,nullptr,0,FILE_NAME_NORMALIZED);if(!n)throw Error("Cannot resolve resource handle");std::wstring path(n,L'\0');DWORD result=GetFinalPathNameByHandleW(handle,path.data(),n,FILE_NAME_NORMALIZED);if(!result||result>=n)throw Error("Cannot resolve resource handle");path.resize(result);return path;};
  HANDLE folder=CreateFileW(base.c_str(),0,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,nullptr);
  if(folder==INVALID_HANDLE_VALUE)throw Error("Cannot open plugin directory");Close folderGuard{folder};
  auto prefix=finalPath(folder)+L"\\",actual=finalPath(file);
  if(actual.size()<=prefix.size()||CompareStringOrdinal(actual.data(),int(prefix.size()),prefix.data(),int(prefix.size()),TRUE)!=CSTR_EQUAL)throw Error("Resource handle escapes plugin directory");
  BY_HANDLE_FILE_INFORMATION info{};if(!GetFileInformationByHandle(file,&info)||(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY))throw Error("Expected resource file");
  auto read=[&](char* data,size_t size)->size_t{DWORD n=0;if(!ReadFile(file,data,DWORD(size),&n,nullptr))throw Error("Resource read failed");return n;};
#else
  int directory=open(root.c_str(),O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW);
  if(directory<0)throw Error("Cannot open plugin directory");
  struct Close {int fd;~Close(){if(fd>=0)::close(fd);}} directoryGuard{directory};
  auto path=std::filesystem::u8path(relative);std::vector<std::filesystem::path> parts;
  for(const auto& part:path)if(part!=".")parts.push_back(part);
  int file=-1;
  for(size_t i=0;i<parts.size();++i){
    int next=openat(directoryGuard.fd,parts[i].c_str(),O_RDONLY|O_NONBLOCK|O_CLOEXEC|O_NOFOLLOW|(i+1<parts.size()?O_DIRECTORY:0));
    if(next<0)throw Error("Resource path unavailable or contains symlink");
    if(i+1<parts.size()){close(directoryGuard.fd);directoryGuard.fd=next;}else file=next;
  }
  Close fileGuard{file};struct stat info{};
  if(file<0||fstat(file,&info)||!S_ISREG(info.st_mode))throw Error("Expected resource file");
  auto read=[&](char* data,size_t size)->size_t{ssize_t n;do{n=::read(file,data,size);}while(n<0&&errno==EINTR);if(n<0)throw Error("Resource read failed");return size_t(n);};
#endif
  std::string result;std::array<char,8192> buffer;
  while(size_t n=read(buffer.data(),std::min(buffer.size(),limit-result.size()+1))){if(n>limit-result.size())throw Error("Resource size limit exceeded");result.append(buffer.data(),n);}
  return result;
}
}
