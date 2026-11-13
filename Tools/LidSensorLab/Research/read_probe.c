// Only statically identified read operations on the lid service. No setters or reset commands.
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
static void dump(const char*n,kern_return_t r,unsigned char*b,size_t size){printf("%s result=0x%x bytes=%zu",n,r,size);if(!r)for(size_t i=0;i<size&&i<80;i++)printf(" %02x",b[i]);puts("");}
int main(){io_iterator_t it=0;IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("AppleSPUInterface"),&it);io_service_t s;while((s=IOIteratorNext(it))){io_name_t name;IORegistryEntryGetName(s,name);if(!strcmp(name,"las")){io_connect_t c=0;kern_return_t r=IOServiceOpen(s,mach_task_self(),0,&c);printf("open=%x\n",r);if(!r){uint64_t props[]={15,16,62};for(int j=0;j<3;j++){unsigned char b[256]={0};size_t n=sizeof(b);r=IOConnectCallMethod(c,2,&props[j],1,NULL,0,NULL,NULL,b,&n);char label[80];snprintf(label,sizeof(label),"get-property %llu",props[j]);dump(label,r,b,n);}uint64_t cmd=6;uint8_t report=7;unsigned char b[64]={0};size_t n=sizeof(b);r=IOConnectCallMethod(c,3,&cmd,1,&report,1,NULL,NULL,b,&n);dump("command 6 / report 7",r,b,n);IOServiceClose(c);}}IOObjectRelease(s);}IOObjectRelease(it);return 0;}
