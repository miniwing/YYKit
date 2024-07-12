//
//  UIDevice+YYAdd.m
//  YYKit <https://github.com/ibireme/YYKit>
//
//  Created by ibireme on 13/4/3.
//  Copyright (c) 2015 ibireme.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "UIDevice+YYAdd.h"
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <mach/mach.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#import "YYKitMacro.h"
#import "NSString+YYAdd.h"

YYSYNTH_DUMMY_CLASS(UIDevice_YYAdd)

NS_INLINE float cpuAppUsage() {
   
   kern_return_t            kr               = KERN_SUCCESS;
   task_info_data_t         tinfo            = {0};
   mach_msg_type_number_t   task_info_count  = {0};
   
   task_info_count = TASK_INFO_MAX;
   kr = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)tinfo, &task_info_count);
   if (kr != KERN_SUCCESS) {
      
      return -1;
   }
   
   task_basic_info_t        basic_info       = {0};
   thread_array_t           thread_list      = {0};
   mach_msg_type_number_t   thread_count     = {0};
   
   thread_info_data_t       thinfo           = {0};
   mach_msg_type_number_t   thread_info_count= {0};
   
   thread_basic_info_t      basic_info_th    = {0};
   uint32_t                 stat_thread      = 0; // Mach threads
   
   basic_info = (task_basic_info_t)tinfo;
   
   // get threads in the task
   kr = task_threads(mach_task_self(), &thread_list, &thread_count);
   if (kr != KERN_SUCCESS) {
      return -1;
   }
   if (thread_count > 0) {
      stat_thread += thread_count;
   }
   
   long   tot_sec    = 0;
   long   tot_usec   = 0;
   float  tot_cpu    = 0;
   
   for (int j = 0; j < thread_count; j++) {
      
      thread_info_count = THREAD_INFO_MAX;
      kr = thread_info(thread_list[j], THREAD_BASIC_INFO,
                       (thread_info_t)thinfo, &thread_info_count);
      if (kr != KERN_SUCCESS) {
         return -1;
      }
      
      basic_info_th = (thread_basic_info_t)thinfo;
      
      if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
         tot_sec = tot_sec + basic_info_th->user_time.seconds + basic_info_th->system_time.seconds;
         tot_usec = tot_usec + basic_info_th->user_time.microseconds + basic_info_th->system_time.microseconds;
         tot_cpu = tot_cpu + basic_info_th->cpu_usage / (float)TH_USAGE_SCALE * 1.0;
      }
      
   } // for each thread
   
   kr = vm_deallocate(mach_task_self(), (vm_offset_t)thread_list, thread_count * sizeof(thread_t));
   assert(kr == KERN_SUCCESS);
   
   //   app_cpu = tot_cpu;
   return tot_cpu;
}

NS_INLINE float cpuSystemUsage() {
   
   static host_cpu_load_info_data_t  previous_info = {0};
   
   kern_return_t                     kr            = KERN_SUCCESS;
   mach_msg_type_number_t            count         = HOST_CPU_LOAD_INFO_COUNT;
   host_cpu_load_info_data_t         info          = {0};
   
   //   count = HOST_CPU_LOAD_INFO_COUNT;
   
   kr = host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count);
   if (kr != KERN_SUCCESS) {
      return -1;
   }
   
   natural_t user   = info.cpu_ticks[CPU_STATE_USER]   - previous_info.cpu_ticks[CPU_STATE_USER];
   natural_t nice   = info.cpu_ticks[CPU_STATE_NICE]   - previous_info.cpu_ticks[CPU_STATE_NICE];
   natural_t system = info.cpu_ticks[CPU_STATE_SYSTEM] - previous_info.cpu_ticks[CPU_STATE_SYSTEM];
   natural_t idle   = info.cpu_ticks[CPU_STATE_IDLE]   - previous_info.cpu_ticks[CPU_STATE_IDLE];
   natural_t total  = user + nice + system + idle;
   
   previous_info    = info;
   
   return (user + nice + system) * 1.0 / total;
}

@implementation UIDevice (YYAdd)

+ (double)systemVersion {
   static double version;
   static dispatch_once_t onceToken;
   dispatch_once(&onceToken, ^{
      version = [UIDevice currentDevice].systemVersion.doubleValue;
   });
   return version;
}

- (BOOL)isPad {
   static dispatch_once_t one;
   static BOOL pad;
   dispatch_once(&one, ^{
      pad = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad;
   });
   return pad;
}

- (BOOL)isSimulator {
#if TARGET_OS_SIMULATOR
   return YES;
#else
   return NO;
#endif
}

- (BOOL)isJailbroken {
   if ([self isSimulator]) return NO; // Dont't check simulator
   
   // iOS9 URL Scheme query changed ...
   // NSURL *cydiaURL = [NSURL URLWithString:@"cydia://package"];
   // if ([[UIApplication sharedApplication] canOpenURL:cydiaURL]) return YES;
   
   NSArray *paths = @[@"/Applications/Cydia.app",
                      @"/private/var/lib/apt/",
                      @"/private/var/lib/cydia",
                      @"/private/var/stash"];
   for (NSString *path in paths) {
      if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
   }
   
   FILE *bash = fopen("/bin/bash", "r");
   if (bash != NULL) {
      fclose(bash);
      return YES;
   }
   
   NSString *path = [NSString stringWithFormat:@"/private/%@", [NSString stringWithUUID]];
   if ([@"test" writeToFile : path atomically : YES encoding : NSUTF8StringEncoding error : NULL]) {
      [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
      return YES;
   }
   
   return NO;
}

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
- (BOOL)canMakePhoneCalls {
   __block BOOL can;
   static dispatch_once_t onceToken;
   dispatch_once(&onceToken, ^{
      can = [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"tel://"]];
   });
   return can;
}
#endif

- (NSString *)ipAddressWithIfaName:(NSString *)name {
   if (name.length == 0) return nil;
   NSString *address = nil;
   struct ifaddrs *addrs = NULL;
   if (getifaddrs(&addrs) == 0) {
      struct ifaddrs *addr = addrs;
      while (addr) {
         if ([[NSString stringWithUTF8String:addr->ifa_name] isEqualToString:name]) {
            sa_family_t family = addr->ifa_addr->sa_family;
            switch (family) {
               case AF_INET: { // IPv4
                  char str[INET_ADDRSTRLEN] = {0};
                  inet_ntop(family, &(((struct sockaddr_in *)addr->ifa_addr)->sin_addr), str, sizeof(str));
                  if (strlen(str) > 0) {
                     address = [NSString stringWithUTF8String:str];
                  }
               } break;
                  
               case AF_INET6: { // IPv6
                  char str[INET6_ADDRSTRLEN] = {0};
                  inet_ntop(family, &(((struct sockaddr_in6 *)addr->ifa_addr)->sin6_addr), str, sizeof(str));
                  if (strlen(str) > 0) {
                     address = [NSString stringWithUTF8String:str];
                  }
               }
                  
               default: break;
            }
            if (address) break;
         }
         addr = addr->ifa_next;
      }
   }
   freeifaddrs(addrs);
   return address;
}

- (NSString *)ipAddressWIFI {
   return [self ipAddressWithIfaName:@"en0"];
}

- (NSString *)ipAddressCell {
   return [self ipAddressWithIfaName:@"pdp_ip0"];
}


typedef struct {
   uint64_t en_in;
   uint64_t en_out;
   uint64_t pdp_ip_in;
   uint64_t pdp_ip_out;
   uint64_t awdl_in;
   uint64_t awdl_out;
} yy_net_interface_counter;


static uint64_t yy_net_counter_add(uint64_t counter, uint64_t bytes) {
   if (bytes < (counter % 0xFFFFFFFF)) {
      counter += 0xFFFFFFFF - (counter % 0xFFFFFFFF);
      counter += bytes;
   } else {
      counter = bytes;
   }
   return counter;
}

static uint64_t yy_net_counter_get_by_type(yy_net_interface_counter *counter, YYNetworkTrafficType type) {
   uint64_t bytes = 0;
   if (type & YYNetworkTrafficTypeWWANSent) bytes += counter->pdp_ip_out;
   if (type & YYNetworkTrafficTypeWWANReceived) bytes += counter->pdp_ip_in;
   if (type & YYNetworkTrafficTypeWIFISent) bytes += counter->en_out;
   if (type & YYNetworkTrafficTypeWIFIReceived) bytes += counter->en_in;
   if (type & YYNetworkTrafficTypeAWDLSent) bytes += counter->awdl_out;
   if (type & YYNetworkTrafficTypeAWDLReceived) bytes += counter->awdl_in;
   return bytes;
}

static yy_net_interface_counter yy_get_net_interface_counter() {
   static dispatch_semaphore_t lock;
   static NSMutableDictionary *sharedInCounters;
   static NSMutableDictionary *sharedOutCounters;
   static dispatch_once_t onceToken;
   dispatch_once(&onceToken, ^{
      sharedInCounters = [NSMutableDictionary new];
      sharedOutCounters = [NSMutableDictionary new];
      lock = dispatch_semaphore_create(1);
   });
   
   yy_net_interface_counter counter = {0};
   struct ifaddrs *addrs;
   const struct ifaddrs *cursor;
   if (getifaddrs(&addrs) == 0) {
      cursor = addrs;
      dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
      while (cursor) {
         if (cursor->ifa_addr->sa_family == AF_LINK) {
            const struct if_data *data = cursor->ifa_data;
            NSString *name = cursor->ifa_name ? [NSString stringWithUTF8String:cursor->ifa_name] : nil;
            if (name) {
               uint64_t counter_in = ((NSNumber *)sharedInCounters[name]).unsignedLongLongValue;
               counter_in = yy_net_counter_add(counter_in, data->ifi_ibytes);
               sharedInCounters[name] = @(counter_in);
               
               uint64_t counter_out = ((NSNumber *)sharedOutCounters[name]).unsignedLongLongValue;
               counter_out = yy_net_counter_add(counter_out, data->ifi_obytes);
               sharedOutCounters[name] = @(counter_out);
               
               if ([name hasPrefix:@"en"]) {
                  counter.en_in += counter_in;
                  counter.en_out += counter_out;
               } else if ([name hasPrefix:@"awdl"]) {
                  counter.awdl_in += counter_in;
                  counter.awdl_out += counter_out;
               } else if ([name hasPrefix:@"pdp_ip"]) {
                  counter.pdp_ip_in += counter_in;
                  counter.pdp_ip_out += counter_out;
               }
            }
         }
         cursor = cursor->ifa_next;
      }
      dispatch_semaphore_signal(lock);
      freeifaddrs(addrs);
   }
   
   return counter;
}

- (uint64_t)getNetworkTrafficBytes:(YYNetworkTrafficType)types {
   yy_net_interface_counter counter = yy_get_net_interface_counter();
   return yy_net_counter_get_by_type(&counter, types);
}

- (NSString *)machineModel {
   static dispatch_once_t one;
   static NSString *model;
   dispatch_once(&one, ^{
      size_t size;
      sysctlbyname("hw.machine", NULL, &size, NULL, 0);
      char *machine = malloc(size);
      sysctlbyname("hw.machine", machine, &size, NULL, 0);
      model = [NSString stringWithUTF8String:machine];
      free(machine);
   });
   return model;
}

- (NSString *)machineModelName {
   static dispatch_once_t one;
   static NSString *name;
   dispatch_once(&one, ^{
      NSString *model = [self machineModel];
      if (!model) return;
      NSDictionary *dic = @{
         @"Watch1,1" : @"Apple Watch 38mm",
         @"Watch1,2" : @"Apple Watch 42mm",
         @"Watch2,3" : @"Apple Watch Series 2 38mm",
         @"Watch2,4" : @"Apple Watch Series 2 42mm",
         @"Watch2,6" : @"Apple Watch Series 1 38mm",
         @"Watch1,7" : @"Apple Watch Series 1 42mm",
         
         @"iPod1,1" : @"iPod touch 1",
         @"iPod2,1" : @"iPod touch 2",
         @"iPod3,1" : @"iPod touch 3",
         @"iPod4,1" : @"iPod touch 4",
         @"iPod5,1" : @"iPod touch 5",
         @"iPod7,1" : @"iPod touch 6",
         
         @"iPhone1,1" : @"iPhone 1G",
         @"iPhone1,2" : @"iPhone 3G",
         @"iPhone2,1" : @"iPhone 3GS",
         @"iPhone3,1" : @"iPhone 4 (GSM)",
         @"iPhone3,2" : @"iPhone 4",
         @"iPhone3,3" : @"iPhone 4 (CDMA)",
         @"iPhone4,1" : @"iPhone 4S",
         @"iPhone5,1" : @"iPhone 5",
         @"iPhone5,2" : @"iPhone 5",
         @"iPhone5,3" : @"iPhone 5c",
         @"iPhone5,4" : @"iPhone 5c",
         @"iPhone6,1" : @"iPhone 5s",
         @"iPhone6,2" : @"iPhone 5s",
         @"iPhone7,1" : @"iPhone 6 Plus",
         @"iPhone7,2" : @"iPhone 6",
         @"iPhone8,1" : @"iPhone 6s",
         @"iPhone8,2" : @"iPhone 6s Plus",
         @"iPhone8,4" : @"iPhone SE",
         @"iPhone9,1" : @"iPhone 7",
         @"iPhone9,2" : @"iPhone 7 Plus",
         @"iPhone9,3" : @"iPhone 7",
         @"iPhone9,4" : @"iPhone 7 Plus",
         
         @"iPad1,1" : @"iPad 1",
         @"iPad2,1" : @"iPad 2 (WiFi)",
         @"iPad2,2" : @"iPad 2 (GSM)",
         @"iPad2,3" : @"iPad 2 (CDMA)",
         @"iPad2,4" : @"iPad 2",
         @"iPad2,5" : @"iPad mini 1",
         @"iPad2,6" : @"iPad mini 1",
         @"iPad2,7" : @"iPad mini 1",
         @"iPad3,1" : @"iPad 3 (WiFi)",
         @"iPad3,2" : @"iPad 3 (4G)",
         @"iPad3,3" : @"iPad 3 (4G)",
         @"iPad3,4" : @"iPad 4",
         @"iPad3,5" : @"iPad 4",
         @"iPad3,6" : @"iPad 4",
         @"iPad4,1" : @"iPad Air",
         @"iPad4,2" : @"iPad Air",
         @"iPad4,3" : @"iPad Air",
         @"iPad4,4" : @"iPad mini 2",
         @"iPad4,5" : @"iPad mini 2",
         @"iPad4,6" : @"iPad mini 2",
         @"iPad4,7" : @"iPad mini 3",
         @"iPad4,8" : @"iPad mini 3",
         @"iPad4,9" : @"iPad mini 3",
         @"iPad5,1" : @"iPad mini 4",
         @"iPad5,2" : @"iPad mini 4",
         @"iPad5,3" : @"iPad Air 2",
         @"iPad5,4" : @"iPad Air 2",
         @"iPad6,3" : @"iPad Pro (9.7 inch)",
         @"iPad6,4" : @"iPad Pro (9.7 inch)",
         @"iPad6,7" : @"iPad Pro (12.9 inch)",
         @"iPad6,8" : @"iPad Pro (12.9 inch)",
         
         @"AppleTV2,1" : @"Apple TV 2",
         @"AppleTV3,1" : @"Apple TV 3",
         @"AppleTV3,2" : @"Apple TV 3",
         @"AppleTV5,3" : @"Apple TV 4",
         
         @"i386" : @"Simulator x86",
         @"x86_64" : @"Simulator x64",
      };
      name = dic[model];
      if (!name) name = model;
   });
   return name;
}

- (NSDate *)systemUptime {
   NSTimeInterval time = [[NSProcessInfo processInfo] systemUptime];
   return [[NSDate alloc] initWithTimeIntervalSinceNow:(0 - time)];
}

- (int64_t)diskSpace {
   NSError *error = nil;
   NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:&error];
   if (error) return -1;
   int64_t space =  [[attrs objectForKey:NSFileSystemSize] longLongValue];
   if (space < 0) space = -1;
   return space;
}

- (int64_t)diskSpaceFree {
   NSError *error = nil;
   NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:&error];
   if (error) return -1;
   int64_t space =  [[attrs objectForKey:NSFileSystemFreeSize] longLongValue];
   if (space < 0) space = -1;
   return space;
}

- (int64_t)diskSpaceUsed {
   int64_t total = self.diskSpace;
   int64_t free = self.diskSpaceFree;
   if (total < 0 || free < 0) return -1;
   int64_t used = total - free;
   if (used < 0) used = -1;
   return used;
}

- (int64_t)memoryTotal {
   int64_t mem = [[NSProcessInfo processInfo] physicalMemory];
   if (mem < -1) mem = -1;
   return mem;
}

- (int64_t)memoryUsed {
   mach_port_t host_port = mach_host_self();
   mach_msg_type_number_t host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
   vm_size_t page_size;
   vm_statistics_data_t vm_stat;
   kern_return_t kern;
   
   kern = host_page_size(host_port, &page_size);
   if (kern != KERN_SUCCESS) return -1;
   kern = host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size);
   if (kern != KERN_SUCCESS) return -1;
   return page_size * (vm_stat.active_count + vm_stat.inactive_count + vm_stat.wire_count);
}

- (int64_t)memoryFree {
   mach_port_t host_port = mach_host_self();
   mach_msg_type_number_t host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
   vm_size_t page_size;
   vm_statistics_data_t vm_stat;
   kern_return_t kern;
   
   kern = host_page_size(host_port, &page_size);
   if (kern != KERN_SUCCESS) return -1;
   kern = host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size);
   if (kern != KERN_SUCCESS) return -1;
   return vm_stat.free_count * page_size;
}

- (int64_t)memoryActive {
   mach_port_t host_port = mach_host_self();
   mach_msg_type_number_t host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
   vm_size_t page_size;
   vm_statistics_data_t vm_stat;
   kern_return_t kern;
   
   kern = host_page_size(host_port, &page_size);
   if (kern != KERN_SUCCESS) return -1;
   kern = host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size);
   if (kern != KERN_SUCCESS) return -1;
   return vm_stat.active_count * page_size;
}

- (int64_t)memoryInactive {
   mach_port_t host_port = mach_host_self();
   mach_msg_type_number_t host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
   vm_size_t page_size;
   vm_statistics_data_t vm_stat;
   kern_return_t kern;
   
   kern = host_page_size(host_port, &page_size);
   if (kern != KERN_SUCCESS) return -1;
   kern = host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size);
   if (kern != KERN_SUCCESS) return -1;
   return vm_stat.inactive_count * page_size;
}

- (int64_t)memoryWired {
   mach_port_t host_port = mach_host_self();
   mach_msg_type_number_t host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
   vm_size_t page_size;
   vm_statistics_data_t vm_stat;
   kern_return_t kern;
   
   kern = host_page_size(host_port, &page_size);
   if (kern != KERN_SUCCESS) return -1;
   kern = host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size);
   if (kern != KERN_SUCCESS) return -1;
   return vm_stat.wire_count * page_size;
}

- (int64_t)memoryPurgable {
   mach_port_t host_port = mach_host_self();
   mach_msg_type_number_t host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
   vm_size_t page_size;
   vm_statistics_data_t vm_stat;
   kern_return_t kern;
   
   kern = host_page_size(host_port, &page_size);
   if (kern != KERN_SUCCESS) return -1;
   kern = host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size);
   if (kern != KERN_SUCCESS) return -1;
   return vm_stat.purgeable_count * page_size;
}

- (NSUInteger)cpuCount {
   return [NSProcessInfo processInfo].activeProcessorCount;
}

- (float)cpuUsage {
   float cpu = 0;
   NSArray *cpus = [self cpuUsagePerProcessor];
   if (cpus.count == 0) return -1;
   for (NSNumber *n in cpus) {
      cpu += n.floatValue;
   }
   return cpu;
}

- (NSArray *)cpuUsagePerProcessor {
   
   processor_info_array_t _cpuInfo = nil;
   mach_msg_type_number_t _numCPUInfo, _numPrevCPUInfo = 0;
   unsigned _numCPUs;
   static NSLock                *_cpuUsageLock = nil;
   static processor_info_array_t _prevCPUInfo  = nil;
   
   int _mib[2U] = { CTL_HW, HW_NCPU };
   size_t _sizeOfNumCPUs = sizeof(_numCPUs);
   int _status = sysctl(_mib, 2U, &_numCPUs, &_sizeOfNumCPUs, NULL, 0U);
   
   if (_status) {
      _numCPUs = 1;
   }
   
   if (nil == _cpuUsageLock) {
      
      _cpuUsageLock = [[NSLock alloc] init];
      
   } /* End if () */
   
   natural_t _numCPUsU = 0U;
   kern_return_t err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &_numCPUsU, &_cpuInfo, &_numCPUInfo);
   if (err == KERN_SUCCESS) {
      [_cpuUsageLock lock];
      
      NSMutableArray *cpus = [NSMutableArray new];
      for (unsigned i = 0U; i < _numCPUs; ++i) {
         Float32 _inUse, _total;
         if (_prevCPUInfo) {
            _inUse = (
                      (_cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_USER]   - _prevCPUInfo[(CPU_STATE_MAX * i) + CPU_STATE_USER])
                      + (_cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_SYSTEM] - _prevCPUInfo[(CPU_STATE_MAX * i) + CPU_STATE_SYSTEM])
                      + (_cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_NICE]   - _prevCPUInfo[(CPU_STATE_MAX * i) + CPU_STATE_NICE])
                      );
            _total = _inUse + (_cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_IDLE] - _prevCPUInfo[(CPU_STATE_MAX * i) + CPU_STATE_IDLE]);
         } else {
            _inUse = _cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_USER] + _cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_SYSTEM] + _cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_NICE];
            _total = _inUse + _cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_IDLE];
            
            _prevCPUInfo   = _cpuInfo;
         }
         [cpus addObject:@(_inUse / _total)];
      }
      
      [_cpuUsageLock unlock];
      if (_prevCPUInfo) {
         size_t prevCpuInfoSize = sizeof(integer_t) * _numPrevCPUInfo;
         vm_deallocate(mach_task_self(), (vm_address_t)_prevCPUInfo, prevCpuInfoSize);
      }
      return cpus;
   } else {
      return nil;
   }
}

- (float)cpuSystemUsageEx {
   
   kern_return_t                     kr            = KERN_SUCCESS;
   mach_msg_type_number_t            count         = HOST_CPU_LOAD_INFO_COUNT;
   static host_cpu_load_info_data_t  previous_info = {0};
   host_cpu_load_info_data_t         info          = {0};
   
   //   count = HOST_CPU_LOAD_INFO_COUNT;
   
   kr = host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count);
   
   if (kr != KERN_SUCCESS) {
      
      return -1;
   }
   
   natural_t user   = info.cpu_ticks[CPU_STATE_USER]   - previous_info.cpu_ticks[CPU_STATE_USER];
   natural_t nice   = info.cpu_ticks[CPU_STATE_NICE]   - previous_info.cpu_ticks[CPU_STATE_NICE];
   natural_t system = info.cpu_ticks[CPU_STATE_SYSTEM] - previous_info.cpu_ticks[CPU_STATE_SYSTEM];
   natural_t idle   = info.cpu_ticks[CPU_STATE_IDLE]   - previous_info.cpu_ticks[CPU_STATE_IDLE];
   natural_t total  = user + nice + system + idle;
   
   LogDebug((@"-[UIDevice systemCpuUsage]1 : user:%d + nice:%d + system:%d + idle:%d",
             info.cpu_ticks[CPU_STATE_USER],
             info.cpu_ticks[CPU_STATE_NICE],
             info.cpu_ticks[CPU_STATE_SYSTEM],
             info.cpu_ticks[CPU_STATE_USER]));
   
   LogDebug((@"-[UIDevice systemCpuUsage]2 : user:%d + nice:%d + system:%d + idle:%d",
             previous_info.cpu_ticks[CPU_STATE_USER],
             previous_info.cpu_ticks[CPU_STATE_NICE],
             previous_info.cpu_ticks[CPU_STATE_SYSTEM],
             previous_info.cpu_ticks[CPU_STATE_USER]));
   
   //   LogDebug((@"-[UIDevice systemCpuUsage] : user:%d + nice:%d + system:%d + total:%d +++ %.2f%%", user, nice, system, total, (user + nice + system) * 100.0 / total));
   
#if __Debug__
   if (0 == total) {
      
      total = total;
      
   } /* End if () */
#endif /* __Debug__ */
   //   memcpy(&previous_info, &info, sizeof(host_cpu_load_info_data_t));
   previous_info  = info;
   
   return (user + nice + system) * 1.0 / total;
}

- (float)cpuSystemUsage {
   
   return cpuSystemUsage();
}

- (float)cpuAppUsageEx {
   
   kern_return_t kr;
   task_info_data_t tinfo;
   mach_msg_type_number_t task_info_count;
   
   task_info_count = TASK_INFO_MAX;
   kr = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)tinfo, &task_info_count);
   if (kr != KERN_SUCCESS) {
      return -1;
   }
   
   task_basic_info_t      basic_info;
   thread_array_t         thread_list;
   mach_msg_type_number_t thread_count;
   
   thread_info_data_t     thinfo;
   mach_msg_type_number_t thread_info_count;
   
   thread_basic_info_t basic_info_th;
   uint32_t stat_thread = 0; // Mach threads
   
   basic_info = (task_basic_info_t)tinfo;
   
   // get threads in the task
   kr = task_threads(mach_task_self(), &thread_list, &thread_count);
   if (kr != KERN_SUCCESS) {
      return -1;
   }
   if (thread_count > 0)
      stat_thread += thread_count;
   
   long tot_sec = 0;
   long tot_usec = 0;
   float tot_cpu = 0;
   int j;
   
   for (j = 0; j < thread_count; j++)
   {
      thread_info_count = THREAD_INFO_MAX;
      kr = thread_info(thread_list[j], THREAD_BASIC_INFO,
                       (thread_info_t)thinfo, &thread_info_count);
      if (kr != KERN_SUCCESS) {
         return -1;
      }
      
      basic_info_th = (thread_basic_info_t)thinfo;
      
      if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
         tot_sec = tot_sec + basic_info_th->user_time.seconds + basic_info_th->system_time.seconds;
         tot_usec = tot_usec + basic_info_th->user_time.microseconds + basic_info_th->system_time.microseconds;
         tot_cpu = tot_cpu + basic_info_th->cpu_usage / (float)TH_USAGE_SCALE;
      }
      
   } // for each thread
   
   kr = vm_deallocate(mach_task_self(), (vm_offset_t)thread_list, thread_count * sizeof(thread_t));
   assert(kr == KERN_SUCCESS);
   
   //    app_cpu = tot_cpu;
   return tot_cpu;
}

- (float)cpuAppUsage {
   
   return cpuAppUsage();
}

NS_INLINE BOOL __CanGetSysCtlBySpecifier(char* specifier, size_t *size) {
   
   if (!specifier || strlen(specifier) == 0 || sysctlbyname(specifier, NULL, size, NULL, 0) == -1 || *size == -1) {
      
      return NO;
   }
   
   return YES;
}

NS_INLINE uint64_t __GetSysCtl64BySpecifier(char* specifier) {
   
   uint64_t val = 0;
   size_t size = sizeof(val);
   
   if (!__CanGetSysCtlBySpecifier(specifier, &size)) {
      return -1;
   }
   
   if (sysctlbyname(specifier, &val, &size, NULL, 0) == -1)
   {
      return -1;
   }
   
   return val;
}

- (NSUInteger)cpuMinFrequency {
   
   return __GetSysCtl64BySpecifier("hw.cpufrequency_min");
}

- (NSUInteger)cpuMaxFrequency {
   
   return __GetSysCtl64BySpecifier("hw.cpufrequency_max");
}

@end
