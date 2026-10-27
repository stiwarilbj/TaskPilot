#import <Foundation/Foundation.h>
#import "ProcessSupport.h"

int tp_file_handle_descriptor(const void *handle) {
    @try {
        return [(__bridge NSFileHandle *)handle fileDescriptor];
    } @catch (NSException *exception) {
        return -1;
    }
}
