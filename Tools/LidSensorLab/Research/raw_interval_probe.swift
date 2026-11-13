import Foundation
import IOKit
import IOKit.hid
func services(_ name:String)->[io_service_t]{var it:io_iterator_t=0;IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching(name),&it);defer{IOObjectRelease(it)};var out:[io_service_t]=[];while case let s=IOIteratorNext(it),s != 0{out.append(s)};return out}
func n(_ s:io_service_t,_ k:String)->Int{(IORegistryEntryCreateCFProperty(s,k as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? NSNumber)?.intValue ?? -1}
var device:IOHIDDevice?
for s in services("AppleSPUHIDDevice"){defer{IOObjectRelease(s)};if n(s,"PrimaryUsagePage")==32 && n(s,"PrimaryUsage")==138{device=IOHIDDeviceCreate(kCFAllocatorDefault,s)}}
guard let d=device,IOHIDDeviceOpen(d,0)==0 else{fatalError("missing device")}
defer{IOHIDDeviceClose(d,0)}
var driver:io_service_t=0
for s in services("AppleSPUHIDDriver"){if n(s,"PrimaryUsagePage")==32 && n(s,"PrimaryUsage")==138{driver=s}else{IOObjectRelease(s)}}
let original = driver==0 ? nil:IORegistryEntryCreateCFProperty(driver,"ReportInterval" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue()
defer{if driver != 0{if let original{IORegistryEntrySetCFProperties(driver,["RawInterval":0,"ReportInterval":original] as CFDictionary)};IOObjectRelease(driver)}}
for phase in ["original","raw-and-report-10000us","restored"]{
 if phase=="raw-and-report-10000us",driver != 0 {
  guard (original as? NSNumber)?.intValue == 0 else { fatalError("Another client owns an interval; refusing to change it") }
  let properties:[String:Any] = ["RawInterval":10000,"ReportInterval":10000]
  print("set raw + report interval result",IORegistryEntrySetCFProperties(driver,properties as CFDictionary))
 }
 if phase=="restored",driver != 0,let original{print("restore",IORegistryEntrySetCFProperties(driver,["RawInterval":0,"ReportInterval":original] as CFDictionary))}
 var reads=0,changes=0,last:Int?,times:[Double]=[],angles:[Double]=[]
 let start=ProcessInfo.processInfo.systemUptime
 while ProcessInfo.processInfo.systemUptime-start<5{
  var b=[UInt8](repeating:0,count:64);var len=64
  if IOHIDDeviceGetReport(d,kIOHIDReportTypeFeature,7,&b,&len)==0,len>=5{
   let raw=Int(b[1])|Int(b[2])<<8|Int(b[3])<<16|Int(b[4])<<24
   if let prior=last,prior != raw{changes+=1;times.append(ProcessInfo.processInfo.systemUptime-start)}
   last=raw;reads+=1;angles.append(Double(raw)/100)
  }
  Thread.sleep(forTimeInterval:0.002)
 }
 let gaps=zip(times.dropFirst(),times).map{$0-$1}.sorted()
 print(phase,"reads",reads,"changes",changes,"median-change-gap-ms",gaps.isEmpty ? -1:gaps[gaps.count/2]*1000,"range",angles.min() ?? -1,angles.max() ?? -1)
 fflush(stdout)
}
