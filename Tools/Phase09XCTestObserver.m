#import <Foundation/Foundation.h>
#import <XCTest/XCTest.h>

@interface Phase09XCTestObserver : NSObject <XCTestObservation>
@property(nonatomic) NSMutableArray<NSString *> *cases;
@property(nonatomic) NSString *outputPath;
@property(nonatomic) BOOL valid;
@property(nonatomic) BOOL succeeded;
@end

@implementation Phase09XCTestObserver

+ (void)load {
    if (getenv("HOSTWRIGHT_PHASE09_XCTEST_XUNIT_OUTPUT") == NULL) {
        return;
    }
    [[XCTestObservationCenter sharedTestObservationCenter] addTestObserver:[[self alloc] init]];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cases = [NSMutableArray array];
        _outputPath = [NSString stringWithUTF8String:getenv("HOSTWRIGHT_PHASE09_XCTEST_XUNIT_OUTPUT")];
        _valid = YES;
        _succeeded = YES;
    }
    return self;
}

- (void)testCaseDidFinish:(XCTestCase *)testCase {
    XCTestRun *run = testCase.testRun;
    if (run == nil || run.failureCount != 0 || !run.hasSucceeded) {
        self.succeeded = NO;
    }
    NSString *name = testCase.name;
    if (![name hasPrefix:@"-["] || ![name hasSuffix:@"]"] || [name rangeOfString:@" "].location == NSNotFound) {
        self.valid = NO;
        return;
    }
    [self.cases addObject:name];
}

- (NSString *)escaped:(NSString *)value {
    NSString *escaped = [value stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    return [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"&apos;"];
}

- (void)testBundleDidFinish:(NSBundle *)testBundle {
    if (self.outputPath.length == 0) {
        return;
    }
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *records = [NSMutableArray array];
    for (NSString *entry in self.cases) {
        NSString *body = [entry substringWithRange:NSMakeRange(2, entry.length - 3)];
        NSRange separator = [body rangeOfString:@" " options:NSBackwardsSearch];
        if (separator.location == NSNotFound || separator.location == 0 || NSMaxRange(separator) >= body.length) {
            self.valid = NO;
            continue;
        }
        NSString *classname = [body substringToIndex:separator.location];
        NSString *name = [body substringFromIndex:NSMaxRange(separator)];
        [records addObject:@{ @"classname": classname, @"name": name }];
    }
    NSMutableString *xml = [NSMutableString string];
    NSUInteger failures = (self.succeeded && self.valid) ? 0 : 1;
    [xml appendFormat:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?><testsuites><testsuite tests=\"%lu\" failures=\"%lu\" errors=\"0\" skipped=\"0\">", (unsigned long)records.count, (unsigned long)failures];
    for (NSDictionary<NSString *, NSString *> *record in records) {
        [xml appendFormat:@"<testcase classname=\"%@\" name=\"%@\"/>", [self escaped:record[@"classname"]], [self escaped:record[@"name"]]];
    }
    [xml appendString:@"</testsuite></testsuites>"];
    NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
    [data writeToFile:self.outputPath options:NSDataWritingAtomic error:nil];
}

@end
