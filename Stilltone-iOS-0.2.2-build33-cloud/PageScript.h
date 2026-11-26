#import <WebKit/WebKit.h>

// The Objective-C entry point is available on iOS 14 and resolves JavaScript promises.
// Some supported runtimes do not ship the separate Swift WebKit overlay.
static inline void STCallPageScript(WKWebView * _Nonnull view, NSString * _Nonnull script,
                                    NSDictionary<NSString *, id> * _Nonnull arguments,
                                    void (^ _Nullable completion)(id _Nullable, NSError * _Nullable)) {
    [view callAsyncJavaScript:script arguments:arguments inFrame:nil
               inContentWorld:WKContentWorld.pageWorld completionHandler:completion];
}
