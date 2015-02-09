/*
 * Authors:
 *  Landon Fuller <landonf@plausiblelabs.com>
 *  Damian Morris <damian@moso.com.au>
 *  Andreas Linde <mail@andreaslinde.de>
 *
 * Copyright (c) 2008-2013 Plausible Labs Cooperative, Inc.
 * Copyright (c) 2010 MOSO Corporation, Pty Ltd.
 * Copyright (c) 2012-2014 HockeyApp, Bit Stadium GmbH.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#import <CrashReporter/CrashReporter.h>

#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach-o/ldsyms.h>
#import <dlfcn.h>
#import <Availability.h>

#if defined(__OBJC2__)
#define SEL_NAME_SECT "__objc_methname"
#else
#define SEL_NAME_SECT "__cstring"
#endif

#import "MSAIExceptionFormatter.h"
#import "MSAICrashData.h"
#import "MSAICrashDataHeaders.h"
#import "MSAICrashDataBinary.h"
#import "MSAICrashDataThreadFrame.h"

/*
 * XXX: The ARM64 CPU type, and ARM_V7S and ARM_V8 Mach-O CPU subtypes are not
 * defined in the Mac OS X 10.8 headers.
 */
#ifndef CPU_SUBTYPE_ARM_V7S
# define CPU_SUBTYPE_ARM_V7S 11
#endif

#ifndef CPU_TYPE_ARM64
#define CPU_TYPE_ARM64 (CPU_TYPE_ARM | CPU_ARCH_ABI64)
#endif

#ifndef CPU_SUBTYPE_ARM_V8
# define CPU_SUBTYPE_ARM_V8 13
#endif


/**
 * Sort PLCrashReportBinaryImageInfo instances by their starting address.
 */
static NSInteger msai_binaryImageSort(id binary1, id binary2, void *context) {
  uint64_t addr1 = [binary1 imageBaseAddress];
  uint64_t addr2 = [binary2 imageBaseAddress];
  
  if (addr1 < addr2)
    return NSOrderedAscending;
  else if (addr1 > addr2)
    return NSOrderedDescending;
  else
    return NSOrderedSame;
}

/**
 * Validates that the given @a string terminates prior to @a limit.
 */
static const char *safer_string_read (const char *string, const char *limit) {
  const char *p = string;
  do {
    if (p >= limit || p+1 >= limit) {
      return NULL;
    }
    p++;
  } while (*p != '\0');
  
  return string;
}

/*
 * The relativeAddress should be `<ecx/rsi/r1/x1 ...> - <image base>`, extracted from the crash report's thread
 * and binary image list.
 *
 * For the (architecture-specific) registers to attempt, see:
 *  http://sealiesoftware.com/blog/archive/2008/09/22/objc_explain_So_you_crashed_in_objc_msgSend.html
 */
static const char *findSEL (const char *imageName, NSString *imageUUID, uint64_t relativeAddress) {
  unsigned int images_count = _dyld_image_count();
  for (unsigned int i = 0; i < images_count; ++i) {
    intptr_t slide = _dyld_get_image_vmaddr_slide(i);
    const struct mach_header *header = _dyld_get_image_header(i);
    const struct mach_header_64 *header64 = (const struct mach_header_64 *) header;
    const char *name = _dyld_get_image_name(i);
    
    /* Image disappeared? */
    if (name == NULL || header == NULL)
      continue;
    
    /* Check if this is the correct image. If we were being even more careful, we'd check the LC_UUID */
    if (strcmp(name, imageName) != 0)
      continue;
    
    /* Determine whether this is a 64-bit or 32-bit Mach-O file */
    BOOL m64 = NO;
    if (header->magic == MH_MAGIC_64)
      m64 = YES;
    
    NSString *uuidString = nil;
    const uint8_t *command;
    uint32_t	ncmds;
    
    if (m64) {
      command = (const uint8_t *)(header64 + 1);
      ncmds = header64->ncmds;
    } else {
      command = (const uint8_t *)(header + 1);
      ncmds = header->ncmds;
    }
    for (uint32_t idx = 0; idx < ncmds; ++idx) {
      const struct load_command *load_command = (const struct load_command *)command;
      if (load_command->cmd == LC_UUID) {
        const struct uuid_command *uuid_command = (const struct uuid_command *)command;
        const uint8_t *uuid = uuid_command->uuid;
        uuidString = [[NSString stringWithFormat:@"%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X",
                       uuid[0], uuid[1], uuid[2], uuid[3],
                       uuid[4], uuid[5], uuid[6], uuid[7],
                       uuid[8], uuid[9], uuid[10], uuid[11],
                       uuid[12], uuid[13], uuid[14], uuid[15]]
                      lowercaseString];
        break;
      } else {
        command += load_command->cmdsize;
      }
    }
    
    // Check if this is the correct image by comparing the UUIDs
    if (!uuidString || ![uuidString isEqualToString:imageUUID])
      continue;
    
    /* Fetch the __objc_methname section */
    const char *methname_sect;
    uint64_t methname_sect_size;
    if (m64) {
      methname_sect = getsectdatafromheader_64(header64, SEG_TEXT, SEL_NAME_SECT, &methname_sect_size);
    } else {
      uint32_t meth_size_32;
      methname_sect = getsectdatafromheader(header, SEG_TEXT, SEL_NAME_SECT, &meth_size_32);
      methname_sect_size = meth_size_32;
    }
    
    /* Apply the slide, as per getsectdatafromheader(3) */
    methname_sect += slide;
    
    if (methname_sect == NULL) {
      return NULL;
    }
    
    /* Calculate the target address within this image, and verify that it is within __objc_methname */
    const char *target = ((const char *)header) + relativeAddress;
    const char *limit = methname_sect + methname_sect_size;
    if (target < methname_sect || target >= limit) {
      return NULL;
    }
    
    /* Read the actual method name */
    return safer_string_read(target, limit);
  }
  
  return NULL;
}

/**
 * Formats PLCrashReport data as human-readable text.
 */
@implementation MSAIExceptionFormatter

+ (MSAICrashData *)crashDataForCrashReport:(PLCrashReport *)report crashReporterKey:(NSString *)crashReporterKey handledException:(NSException *)exception{
  
  MSAICrashData *crashData = [MSAICrashData new];
  MSAICrashDataHeaders *crashHeaders = [MSAICrashDataHeaders new];
  NSString *unknownString = @"???";
  
  boolean_t lp64 = true; // quiesce GCC uninitialized value warning
  
  /* Map to Apple-style code type, and mark whether architecture is LP64 (64-bit) */
  NSNumber *codeType = nil;
  {
    /* Attempt to derive the code type from the binary images */
    for (MSAIPLCrashReportBinaryImageInfo *image in report.images) {
      /* Skip images with no specified type */
      if (image.codeType == nil)
        continue;
      
      /* Skip unknown encodings */
      if (image.codeType.typeEncoding != PLCrashReportProcessorTypeEncodingMach)
        continue;
      
      codeType = @(image.codeType.type);
      
      /* Stop immediately if code type was discovered */
      if (codeType != nil)
        break;
    }
    
    /* If we were unable to determine the code type, fall back on the legacy architecture value. */
    if (codeType == nil) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated"
      switch (report.systemInfo.architecture) {
#pragma clang diagnostic pop
        case PLCrashReportArchitectureARMv6:
        case PLCrashReportArchitectureARMv7:
          codeType = @(CPU_TYPE_ARM);
          lp64 = false;
          break;
        case PLCrashReportArchitectureX86_32:
          codeType = @(CPU_TYPE_X86);
          lp64 = false;
          break;
        case PLCrashReportArchitectureX86_64:
          codeType = @(CPU_TYPE_X86_64);
          lp64 = true;
          break;
        case PLCrashReportArchitecturePPC:
          codeType = @(CPU_TYPE_POWERPC);
          lp64 = false;
          break;
        default:
          lp64 = true;
          break;
      }
    }
  }
  
  {
    NSString *crashDataHeadersId = @"???";
    if (crashReporterKey && [crashReporterKey length] > 0)
      crashDataHeadersId = crashReporterKey;
    
    NSString *incidentIdentifier = @"???";
    if (report.uuidRef != NULL) {
      incidentIdentifier = (NSString *) CFBridgingRelease(CFUUIDCreateString(NULL, report.uuidRef));
    }
  }
  
  /* Application and process info */
  {
    NSString *processName = unknownString;
    NSString *processPath = unknownString;
    NSString *parentProcessName = unknownString;
    NSNumber *processId = nil;
    NSNumber *parentProcessId = nil;
    
    /* Process information was not available in earlier crash report versions */
    if (report.hasProcessInfo) {
      /* Process Name */
      if (report.processInfo.processName != nil)
        processName = report.processInfo.processName;
      
      /* PID */
      processId = @(report.processInfo.processID);
      
      /* Process Path */
      if (report.processInfo.processPath != nil) {
        processPath = report.processInfo.processPath;
        
        /* Remove username from the path */
        if ([processPath length] > 0)
          processPath = [processPath stringByAbbreviatingWithTildeInPath];
        if ([processPath length] > 0 && [[processPath substringToIndex:1] isEqualToString:@"~"])
          processPath = [NSString stringWithFormat:@"/Users/USER%@", [processPath substringFromIndex:1]];
      }
      
      /* Parent Process Name */
      if (report.processInfo.parentProcessName != nil)
        parentProcessName = report.processInfo.parentProcessName;
      
      /* Parent Process ID */
      parentProcessId = @(report.processInfo.parentProcessID);
    }
    
    crashHeaders.process = processName;
    crashHeaders.processId = processId;
    crashHeaders.parentProcess = parentProcessName;
    crashHeaders.parentProcessId = parentProcessId;
    crashHeaders.applicationIdentifier = report.applicationInfo.applicationIdentifier;
    crashHeaders.applicationBuild = report.applicationInfo.applicationVersion;
    crashHeaders.applicationPath = processPath;
  }
  
  /* Exception code */
  crashHeaders.exceptionAddress = [NSString stringWithFormat:@"0x%" PRIx64, report.signalInfo.address];
  crashHeaders.exceptionType = (exception) ? exception.name : report.signalInfo.name;
  crashHeaders.exceptionReason = (exception) ? exception.reason : nil;
  crashHeaders.exceptionCode = report.signalInfo.code;
  
  for (MSAIPLCrashReportThreadInfo *thread in report.threads) {
    if (thread.crashed) {
      crashHeaders.crashThread = @(thread.threadNumber);
      break;
    }
  }
  
  MSAIPLCrashReportThreadInfo *crashed_thread = nil;
  for (MSAIPLCrashReportThreadInfo *thread in report.threads) {
    if (thread.crashed) {
      crashed_thread = thread;
      break;
    }
  }
  
  /* Uncaught Exception */
  if (report.hasExceptionInfo) {
    crashHeaders.exceptionReason = report.exceptionInfo.exceptionReason;
  } else if (crashed_thread != nil) {
    // try to find the selector in case this was a crash in obj_msgSend
    // we search this wether the crash happend in obj_msgSend or not since we don't have the symbol!
    
    NSString *foundSelector = nil;
    
    // search the registers value for the current arch
#if TARGET_IPHONE_SIMULATOR
    if (lp64) {
      foundSelector = [[self class] selectorForRegisterWithName:@"rsi" ofThread:crashed_thread report:report];
      if (foundSelector == NULL)
        foundSelector = [[self class] selectorForRegisterWithName:@"rdx" ofThread:crashed_thread report:report];
    } else {
      foundSelector = [[self class] selectorForRegisterWithName:@"ecx" ofThread:crashed_thread report:report];
    }
#else
    if (lp64) {
      foundSelector = [[self class] selectorForRegisterWithName:@"x1" ofThread:crashed_thread report:report];
    } else {
      foundSelector = [[self class] selectorForRegisterWithName:@"r1" ofThread:crashed_thread report:report];
      if (foundSelector == NULL)
        foundSelector = [[self class] selectorForRegisterWithName:@"r2" ofThread:crashed_thread report:report];
    }
#endif
    
    if (foundSelector) {
      crashHeaders.exceptionReason = [NSString stringWithFormat:@"Selector name found in current argument registers: %@\n", foundSelector];
    }
  }
  
  crashData.headers = crashHeaders;
  
  /* If an exception stack trace is available, output an Apple-compatible backtrace. */
  if (report.exceptionInfo != nil && report.exceptionInfo.stackFrames != nil && [report.exceptionInfo.stackFrames count] > 0) {
    MSAIPLCrashReportExceptionInfo *exception = report.exceptionInfo;
    
    MSAICrashDataThread *threadData = [MSAICrashDataThread new];
    threadData.crashDataThreadId = @(-1);
    
    /* Write out the frames. In raw reports, Apple writes this out as a simple list of PCs. In the minimally
     * post-processed report, Apple writes this out as full frame entries. We use the latter format. */
    for (NSUInteger frame_idx = 0; frame_idx < [exception.stackFrames count]; frame_idx++) {
      MSAIPLCrashReportStackFrameInfo *frameInfo = exception.stackFrames[frame_idx];
      
      
      MSAICrashDataThreadFrame *frame = [[self class] msai_formatStackFrame: frameInfo frameIndex: frame_idx report: report lp64: lp64];
      [threadData.frames addObject:frame];
    }
    [crashData.threads addObject:threadData];
  }
  
  
  
  /* Threads */
  for (MSAIPLCrashReportThreadInfo *thread in report.threads) {
    MSAICrashDataThread *threadData = [MSAICrashDataThread new];
    threadData.crashDataThreadId = @(thread.threadNumber);
    
    for (NSUInteger frame_idx = 0; frame_idx < [thread.stackFrames count]; frame_idx++) {
      MSAIPLCrashReportStackFrameInfo *frameInfo = thread.stackFrames[frame_idx];
      MSAICrashDataThreadFrame *frame = [[self class] msai_formatStackFrame: frameInfo frameIndex: frame_idx report: report lp64: lp64];
      [threadData.frames addObject:frame];
    }
    
    /* Registers */
    if(thread.crashed){
      
      for (MSAIPLCrashReportRegisterInfo *reg in crashed_thread.registers) {
        
        /* Remap register names to match Apple's crash reports */
        NSString *regName = reg.registerName;
        if (report.machineInfo != nil && report.machineInfo.processorInfo.typeEncoding == PLCrashReportProcessorTypeEncodingMach) {
          MSAIPLCrashReportProcessorInfo *pinfo = report.machineInfo.processorInfo;
          cpu_type_t arch_type = pinfo.type & ~CPU_ARCH_MASK;
          
          /* Apple uses 'ip' rather than 'r12' on ARM */
          if (arch_type == CPU_TYPE_ARM && [regName isEqual: @"r12"]) {
            regName = @"ip";
          }
        }
        
        NSString *formattedRegName = [NSString stringWithFormat:@"%6s", [regName UTF8String]];
        NSString *formattedRegValue = @"";
        /* Use 32-bit or 64-bit fixed width format for the register values */
        if (lp64){
          
          formattedRegValue = [NSString stringWithFormat:@"0x%016" PRIx64, reg.registerValue];
        }else{
          formattedRegValue = [NSString stringWithFormat:@"0x%08" PRIx64, reg.registerValue];
        }
        
        if(threadData.frames.count > 0){
          [[(MSAICrashDataThreadFrame *)threadData.frames[0] registers] setValue:formattedRegValue forKey:formattedRegName];
        }
      }
    }
    
    [crashData.threads addObject:threadData];
  }
  
  /* Images. The iPhone crash report format sorts these in ascending order, by the base address */
  NSMutableArray *binaries = [NSMutableArray new];
  for (MSAIPLCrashReportBinaryImageInfo *imageInfo in [report.images sortedArrayUsingFunction: msai_binaryImageSort context: nil]) {
    
    MSAICrashDataBinary *binary = [MSAICrashDataBinary new];
    
    /* Fetch the UUID if it exists */
    binary.uuid = (imageInfo.hasImageUUID) ? imageInfo.imageUUID : unknownString;
    
    /* Determine the architecture string */
    binary.cpuType = codeType;
    binary.cpuSubType = @(imageInfo.codeType.subtype);
    
    /* Determine if this is the main executable or an app specific framework*/
    MSAIBinaryImageType imageType = [[self class] msai_imageTypeForImagePath:imageInfo.imageName
                                                                 processPath:report.processInfo.processPath];
    NSString *binaryDesignator = @" ";
    if (imageType != MSAIBinaryImageTypeOther) {
      binaryDesignator = @"+";
    }
    
    /* Remove username from the image path */
    NSString *imageName = @"";
    if (imageInfo.imageName && [imageInfo.imageName length] > 0)
      imageName = [imageInfo.imageName stringByAbbreviatingWithTildeInPath];
    if ([imageName length] > 0 && [[imageName substringToIndex:1] isEqualToString:@"~"])
      imageName = [NSString stringWithFormat:@"/Users/USER%@", [imageName substringFromIndex:1]];
    
    binary.path = imageName;
    
    NSString *fmt = (lp64) ? @"%18#" PRIx64 : @"%10#" PRIx64;
    
    binary.startAddress = [NSString stringWithFormat:fmt, imageInfo.imageBaseAddress];
    binary.endAddress = [NSString stringWithFormat:fmt, imageInfo.imageBaseAddress + (MAX(1, imageInfo.imageSize) - 1)];
    binary.name = [NSString stringWithFormat:@"%@%@", binaryDesignator, [imageInfo.imageName lastPathComponent]];
    
    [binaries addObject:binary];
  }
  
  crashData.binaries = binaries;
  
  return crashData;
}

/**
 * Formats the provided @a report as human-readable text in the given @a textFormat, and return
 * the formatted result as a string.
 *
 * @param report The report to format.
 * @param textFormat The text format to use.
 *
 * @return Returns the formatted result on success, or nil if an error occurs.
 */
+ (MSAICrashData *)crashDataForCrashReport:(MSAIPLCrashReport *)report crashReporterKey:(NSString *)crashReporterKey {
  
  return [[self class]crashDataForCrashReport:report crashReporterKey:crashReporterKey handledException:nil];
}

/**
 *  Return the selector string of a given register name
 *
 *  @param regName The name of the register to use for getting the address
 *  @param thread  The crashed thread
 *  @param images  NSArray of binary images
 *
 *  @return The selector as a C string or NULL if no selector was found
 */
+ (NSString *)selectorForRegisterWithName:(NSString *)regName ofThread:(MSAIPLCrashReportThreadInfo *)thread report:(MSAIPLCrashReport *)report {
  // get the address for the register
  uint64_t regAddress = 0;
  
  for (MSAIPLCrashReportRegisterInfo *reg in thread.registers) {
    if ([reg.registerName isEqualToString:regName]) {
      regAddress = reg.registerValue;
      break;
    }
  }
  
  if (regAddress == 0)
    return nil;
  
  MSAIPLCrashReportBinaryImageInfo *imageForRegAddress = [report imageForAddress:regAddress];
  if (imageForRegAddress) {
    // get the SEL
    const char *foundSelector = findSEL([imageForRegAddress.imageName UTF8String], imageForRegAddress.imageUUID, regAddress - (uint64_t)imageForRegAddress.imageBaseAddress);
    
    if (foundSelector != NULL) {
      return [NSString stringWithUTF8String:foundSelector];
    }
  }
  
  return nil;
}


/**
 * Returns an array of app UUIDs and their architecture
 * As a dictionary for each element
 *
 * @param report The report to format.
 *
 * @return Returns the formatted result on success, or nil if an error occurs.
 */
+ (NSArray *)arrayOfAppUUIDsForCrashReport:(MSAIPLCrashReport *)report {
  NSMutableArray* appUUIDs = [NSMutableArray array];
  
  /* Images. The iPhone crash report format sorts these in ascending order, by the base address */
  for (MSAIPLCrashReportBinaryImageInfo *imageInfo in [report.images sortedArrayUsingFunction: msai_binaryImageSort context: nil]) {
    NSString *uuid;
    /* Fetch the UUID if it exists */
    if (imageInfo.hasImageUUID)
      uuid = imageInfo.imageUUID;
    else
      uuid = @"???";
    
    /* Determine the architecture string */
    NSString *archName = [[self class] msai_archNameFromImageInfo:imageInfo];
    
    /* Determine if this is the app executable or app specific framework */
    MSAIBinaryImageType imageType = [[self class] msai_imageTypeForImagePath:imageInfo.imageName
                                                                 processPath:report.processInfo.processPath];
    NSString *imageTypeString = @"";
    
    if (imageType != MSAIBinaryImageTypeOther) {
      if (imageType == MSAIBinaryImageTypeAppBinary) {
        imageTypeString = @"app";
      } else {
        imageTypeString = @"framework";
      }
      
      [appUUIDs addObject:@{kMSAIBinaryImageKeyUUID: uuid,
                            kMSAIBinaryImageKeyArch: archName,
                            kMSAIBinaryImageKeyType: imageTypeString}
       ];
    }
  }
  
  return appUUIDs;
}

/* Determine if in binary image is the app executable or app specific framework */
+ (MSAIBinaryImageType)msai_imageTypeForImagePath:(NSString *)imagePath processPath:(NSString *)processPath {
  MSAIBinaryImageType imageType = MSAIBinaryImageTypeOther;
  
  NSString *standardizedImagePath = [[imagePath stringByStandardizingPath] lowercaseString];
  imagePath = [imagePath lowercaseString];
  processPath = [processPath lowercaseString];
  
  NSRange appRange = [standardizedImagePath rangeOfString: @".app/"];
  
  // Exclude iOS swift dylibs. These are provided as part of the app binary by Xcode for now, but we never get a dSYM for those.
  NSRange swiftLibRange = [standardizedImagePath rangeOfString:@"frameworks/libswift"];
  BOOL dylibSuffix = [standardizedImagePath hasSuffix:@".dylib"];
  
  if (appRange.location != NSNotFound && !(swiftLibRange.location != NSNotFound && dylibSuffix)) {
    NSString *appBundleContentsPath = [standardizedImagePath substringToIndex:appRange.location + 5];
    
    if ([standardizedImagePath isEqual: processPath] ||
        // Fix issue with iOS 8 `stringByStandardizingPath` removing leading `/private` path (when not running in the debugger or simulator only)
        [imagePath hasPrefix:processPath]) {
      imageType = MSAIBinaryImageTypeAppBinary;
    } else if ([standardizedImagePath hasPrefix:appBundleContentsPath] ||
               // Fix issue with iOS 8 `stringByStandardizingPath` removing leading `/private` path (when not running in the debugger or simulator only)
               [imagePath hasPrefix:appBundleContentsPath]) {
      imageType = MSAIBinaryImageTypeAppFramework;
    }
  }
  
  return imageType;
}

+ (NSString *)msai_archNameFromImageInfo:(MSAIPLCrashReportBinaryImageInfo *)imageInfo
{
  NSString *archName = @"???";
  if (imageInfo.codeType != nil && imageInfo.codeType.typeEncoding == PLCrashReportProcessorTypeEncodingMach) {
    archName = [[self class] msai_archNameFromCPUType:imageInfo.codeType.type subType:imageInfo.codeType.subtype];
  }
  
  return archName;
}

+ (NSString *)msai_archNameFromCPUType:(uint64_t)cpuType subType:(uint64_t)subType {
  NSString *archName = @"???";
  switch (cpuType) {
    case CPU_TYPE_ARM:
      /* Apple includes subtype for ARM binaries. */
      switch (subType) {
        case CPU_SUBTYPE_ARM_V6:
          archName = @"armv6";
          break;
          
        case CPU_SUBTYPE_ARM_V7:
          archName = @"armv7";
          break;
          
        case CPU_SUBTYPE_ARM_V7S:
          archName = @"armv7s";
          break;
          
        default:
          archName = @"arm-unknown";
          break;
      }
      break;
      
    case CPU_TYPE_ARM64:
      /* Apple includes subtype for ARM64 binaries. */
      switch (subType) {
        case CPU_SUBTYPE_ARM_ALL:
          archName = @"arm64";
          break;
          
        case CPU_SUBTYPE_ARM_V8:
          archName = @"arm64";
          break;
          
        default:
          archName = @"arm64-unknown";
          break;
      }
      break;
      
    case CPU_TYPE_X86:
      archName = @"i386";
      break;
      
    case CPU_TYPE_X86_64:
      archName = @"x86_64";
      break;
      
    case CPU_TYPE_POWERPC:
      archName = @"powerpc";
      break;
      
    default:
      // Use the default archName value (initialized above).
      break;
  }
  
  return archName;
}

/**
 * Format a stack frame for display in a thread backtrace.
 *
 * @param frameInfo The stack frame to format
 * @param frameIndex The frame's index
 * @param report The report from which this frame was acquired.
 * @param lp64 If YES, the report was generated by an LP64 system.
 *
 * @return Returns a formatted frame line.
 */
+ (MSAICrashDataThreadFrame *)msai_formatStackFrame: (MSAIPLCrashReportStackFrameInfo *) frameInfo
                                         frameIndex: (NSUInteger) frameIndex
                                             report: (MSAIPLCrashReport *) report
                                               lp64: (BOOL) lp64
{
  /* Base image address containing instrumention pointer, offset of the IP from that base
   * address, and the associated image name */
  uint64_t baseAddress = 0x0;
  uint64_t pcOffset = 0x0;
  NSString *imageName = @"\?\?\?";
  NSString *symbolString = nil;
  
  MSAIPLCrashReportBinaryImageInfo *imageInfo = [report imageForAddress: frameInfo.instructionPointer];
  if (imageInfo != nil) {
    imageName = [imageInfo.imageName lastPathComponent];
    baseAddress = imageInfo.imageBaseAddress;
    pcOffset = frameInfo.instructionPointer - imageInfo.imageBaseAddress;
  }
  
  /* Make sure UTF8/16 characters are handled correctly */
  NSInteger offset = 0;
  NSInteger index = 0;
  for (index = 0; index < [imageName length]; index++) {
    NSRange range = [imageName rangeOfComposedCharacterSequenceAtIndex:index];
    if (range.length > 1) {
      offset += range.length - 1;
      index += range.length - 1;
    }
    if (index > 32) {
      imageName = [NSString stringWithFormat:@"%@... ", [imageName substringToIndex:index - 1]];
      index += 3;
      break;
    }
  }
  if (index-offset < 36) {
    imageName = [imageName stringByPaddingToLength:36+offset withString:@" " startingAtIndex:0];
  }
  
  /* If symbol info is available, the format used in Apple's reports is Sym + OffsetFromSym. Otherwise,
   * the format used is imageBaseAddress + offsetToIP */
  MSAIBinaryImageType imageType = [[self class] msai_imageTypeForImagePath:imageInfo.imageName
                                                               processPath:report.processInfo.processPath];
  if (frameInfo.symbolInfo != nil && imageType == MSAIBinaryImageTypeOther) {
    NSString *symbolName = frameInfo.symbolInfo.symbolName;
    
    /* Apple strips the _ symbol prefix in their reports. Only OS X makes use of an
     * underscore symbol prefix by default. */
    if ([symbolName rangeOfString: @"_"].location == 0 && [symbolName length] > 1) {
      switch (report.systemInfo.operatingSystem) {
        case PLCrashReportOperatingSystemMacOSX:
        case PLCrashReportOperatingSystemiPhoneOS:
        case PLCrashReportOperatingSystemiPhoneSimulator:
          symbolName = [symbolName substringFromIndex: 1];
          break;
          
        default:
          NSLog(@"Symbol prefix rules are unknown for this OS!");
          break;
      }
    }
    
    
    uint64_t symOffset = frameInfo.instructionPointer - frameInfo.symbolInfo.startAddress;
    symbolString = [NSString stringWithFormat: @"%@ + %" PRId64, symbolName, symOffset];
  } else {
    symbolString = [NSString stringWithFormat: @"0x%" PRIx64 " + %" PRId64, baseAddress, pcOffset];
  }
  
  /* Note that width specifiers are ignored for %@, but work for C strings.
   * UTF-8 is not correctly handled with %s (it depends on the system encoding), but
   * UTF-16 is supported via %S, so we use it here */
  MSAICrashDataThreadFrame *frame = [MSAICrashDataThreadFrame new];
  frame.address = [NSString stringWithFormat:@"0x%0*" PRIx64, lp64 ? 16 : 8, frameInfo.instructionPointer];
  frame.symbol = symbolString;
  
  return frame;
}

@end