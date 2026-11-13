// Only statically identified read operations on the lid service. No setters or reset commands.
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
static void dump(const char*n,kern_return_t r,unsigned char*b,size_t size){printf("%s result=0x%x bytes=%zu",n,r,size);if(!r)for(size_t i=0;i<size&&i<80;i++)printf(" %02x",b[i]);puts("");}
int main(){io_iterator_t it=0;IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("AppleSPUHIDDevice"),&it);io_service_t s;while((s=IOIteratorNext(it))){io_name_t name;IORegistryEntryGetName(s,name);CFTypeRef pp=IORegistryEntryCreateCFProperty(s,CFSTR("PrimaryUsagePage"),kCFAllocatorDefault,0), uu=IORegistryEntryCreateCFProperty(s,CFSTR("PrimaryUsage"),kCFAllocatorDefault,0);int page=-1,usage=-1;if(pp){CFNumberGetValue(pp,kCFNumberIntType,&page);CFRelease(pp);}if(uu){CFNumberGetValue(uu,kCFNumberIntType,&usage);CFRelease(uu);}if(page==32&&usage==138){io_connect_t c=0;kern_return_t r=IOServiceOpen(s,mach_task_self(),0x61736864,&c);printf("open=%x\n",r);if(!r){uint64_t cmd=6;uint8_t report=7;unsigned char b[64]={0};size_t n=sizeof(b);r=IOConnectCallMethod(c,6,&cmd,1,&report,1,NULL,NULL,b,&n);dump("command 6 / report 7",r,b,n);IOServiceClose(c);}}IOObjectRelease(s);}IOObjectRelease(it);return 0;}
