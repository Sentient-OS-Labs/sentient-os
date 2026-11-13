#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
static int is_lid(io_service_t s){CFTypeRef p=IORegistryEntryCreateCFProperty(s,CFSTR("Product"),kCFAllocatorDefault,0);int ok=p&&CFGetTypeID(p)==CFStringGetTypeID()&&CFEqual(p,CFSTR("las"));if(p)CFRelease(p);io_name_t n;if(IORegistryEntryGetName(s,n)==0&&!strcmp(n,"las"))ok=1;return ok;}
int main(){const char*classes[]={"AppleSPUInterface","AppleSPUHIDDevice","AppleSPUHIDDriver"};for(int i=0;i<3;i++){io_iterator_t it=0;IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching(classes[i]),&it);io_service_t s;while((s=IOIteratorNext(it))){if(is_lid(s)){uint32_t types[]={0,0x61736864};for(int j=0;j<(i==1?2:1);j++){io_connect_t c=0;kern_return_t r=IOServiceOpen(s,mach_task_self(),types[j],&c);printf("%s type=0x%x result=0x%x connection=%u\n",classes[i],types[j],r,c);if(!r)IOServiceClose(c);}}IOObjectRelease(s);}IOObjectRelease(it);}return 0;}
