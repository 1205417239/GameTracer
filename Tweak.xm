#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <substrate.h>

#pragma mark - IL2CPP 函数指针类型定义
typedef void* (*il2cpp_domain_get_t)(void);
typedef void** (*il2cpp_domain_get_assemblies_t)(void* domain, size_t* size);
typedef void* (*il2cpp_assembly_get_image_t)(void* assembly);
typedef void* (*il2cpp_class_from_name_t)(void* image, const char* namespaze, const char* name);
typedef void* (*il2cpp_class_get_methods_t)(void* klass, void* iter);
typedef const char* (*il2cpp_method_get_name_t)(void* method);
typedef void* (*il2cpp_method_get_class_t)(void* method);
typedef const char* (*il2cpp_class_get_name_t)(void* klass);
typedef const char* (*il2cpp_class_get_namespace_t)(void* klass);
typedef void* (*il2cpp_runtime_invoke_t)(void* method, void* obj, void** params, void** exc);
typedef void* (*il2cpp_object_unbox_t)(void* obj);
typedef int (*il2cpp_method_get_param_count_t)(void* method);
typedef void* (*il2cpp_field_get_value_t)(void* obj, void* field);
typedef void* (*il2cpp_class_get_field_from_name_t)(void* klass, const char* name);
typedef const char* (*il2cpp_field_get_name_t)(void* field);
typedef int (*il2cpp_field_get_type_t)(void* field);

#pragma mark - 全局变量
static il2cpp_runtime_invoke_t orig_il2cpp_runtime_invoke = NULL;
static void* il2cpp_image = NULL;
static BOOL g_tracer_enabled = YES;
static int g_invoke_count = 0;
static NSMutableDictionary *g_method_call_count = nil;
static NSMutableArray *g_time_changes = nil;
static float g_last_timeScale = 1.0f;
static float g_last_maximumDeltaTime = 0.3333f;
static int g_last_targetFrameRate = -1;
static int g_last_vSyncCount = 1;

// 缓存的 IL2CPP 函数指针（避免每次 dlsym）
static il2cpp_method_get_name_t g_method_get_name = NULL;
static il2cpp_method_get_class_t g_method_get_class = NULL;
static il2cpp_class_get_name_t g_class_get_name = NULL;
static il2cpp_class_get_namespace_t g_class_get_namespace = NULL;
static il2cpp_class_from_name_t g_class_from_name = NULL;
static il2cpp_class_get_field_from_name_t g_class_get_field_from_name = NULL;
static il2cpp_field_get_value_t g_field_get_value = NULL;
static il2cpp_object_unbox_t g_object_unbox = NULL;
static il2cpp_domain_get_t g_domain_get = NULL;
static il2cpp_domain_get_assemblies_t g_domain_get_assemblies = NULL;
static il2cpp_assembly_get_image_t g_assembly_get_image = NULL;
static BOOL g_funcs_cached = NO;

// 前向声明
static void* get_il2cpp_func(const char *name);

static void cache_il2cpp_funcs(void) {
    if (g_funcs_cached) return;
    g_funcs_cached = YES;
    
    g_method_get_name = (il2cpp_method_get_name_t)get_il2cpp_func("il2cpp_method_get_name");
    g_method_get_class = (il2cpp_method_get_class_t)get_il2cpp_func("il2cpp_method_get_class");
    g_class_get_name = (il2cpp_class_get_name_t)get_il2cpp_func("il2cpp_class_get_name");
    g_class_get_namespace = (il2cpp_class_get_namespace_t)get_il2cpp_func("il2cpp_class_get_namespace");
    g_class_from_name = (il2cpp_class_from_name_t)get_il2cpp_func("il2cpp_class_from_name");
    g_class_get_field_from_name = (il2cpp_class_get_field_from_name_t)get_il2cpp_func("il2cpp_class_get_field_from_name");
    g_field_get_value = (il2cpp_field_get_value_t)get_il2cpp_func("il2cpp_field_get_value");
    g_object_unbox = (il2cpp_object_unbox_t)get_il2cpp_func("il2cpp_object_unbox");
    g_domain_get = (il2cpp_domain_get_t)get_il2cpp_func("il2cpp_domain_get");
    g_domain_get_assemblies = (il2cpp_domain_get_assemblies_t)get_il2cpp_func("il2cpp_domain_get_assemblies");
    g_assembly_get_image = (il2cpp_assembly_get_image_t)get_il2cpp_func("il2cpp_assembly_get_image");
}

#pragma mark - 日志文件
static NSString *logFilePath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = paths.firstObject;
    return [docDir stringByAppendingPathComponent:@"GameTracer_log.txt"];
}

static void writeLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSLog(@"[GameTracer] %@", msg);
    
    NSString *path = logFilePath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    [fh seekToEndOfFile];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

#pragma mark - 获取 IL2CPP 函数
static void* get_il2cpp_func(const char *name) {
    void *handle = dlopen("/usr/lib/libil2cpp.dylib", RTLD_LAZY);
    if (!handle) {
        // 尝试从主程序中查找
        handle = dlopen(NULL, RTLD_LAZY);
    }
    if (handle) {
        return dlsym(handle, name);
    }
    return dlsym(RTLD_DEFAULT, name);
}

#pragma mark - 查找 Unity 类
static void* find_unity_class(const char *name) {
    if (!il2cpp_image || !g_class_from_name) return NULL;
    
    // 尝试不同的命名空间
    const char *namespaces[] = {"UnityEngine", "", "UnityEngine.CoreModule", NULL};
    for (int i = 0; namespaces[i]; i++) {
        void *klass = g_class_from_name(il2cpp_image, namespaces[i], name);
        if (klass) return klass;
    }
    return NULL;
}

#pragma mark - 获取 Time 类静态字段值
static float get_time_static_float(const char *fieldName) {
    void *timeClass = find_unity_class("Time");
    if (!timeClass || !g_class_get_field_from_name || !g_field_get_value || !g_object_unbox) return -1;
    
    void *field = g_class_get_field_from_name(timeClass, fieldName);
    if (!field) return -1;
    
    void *value = g_field_get_value(NULL, field);
    if (!value) return -1;
    
    float *fval = (float *)g_object_unbox(value);
    return fval ? *fval : -1;
}

static int get_application_static_int(const char *fieldName) {
    void *appClass = find_unity_class("Application");
    if (!appClass || !g_class_get_field_from_name || !g_field_get_value || !g_object_unbox) return -1;
    
    void *field = g_class_get_field_from_name(appClass, fieldName);
    if (!field) return -1;
    
    void *value = g_field_get_value(NULL, field);
    if (!value) return -1;
    
    int *ival = (int *)g_object_unbox(value);
    return ival ? *ival : -1;
}

static int get_quality_static_int(const char *fieldName) {
    void *qClass = find_unity_class("QualitySettings");
    if (!qClass || !g_class_get_field_from_name || !g_field_get_value || !g_object_unbox) return -1;
    
    void *field = g_class_get_field_from_name(qClass, fieldName);
    if (!field) return -1;
    
    void *value = g_field_get_value(NULL, field);
    if (!value) return -1;
    
    int *ival = (int *)g_object_unbox(value);
    return ival ? *ival : -1;
}

#pragma mark - 监控时间属性变化
static void check_time_changes(void) {
    float timeScale = get_time_static_float("timeScale");
    float maximumDeltaTime = get_time_static_float("maximumDeltaTime");
    float deltaTime = get_time_static_float("deltaTime");
    float realtimeSinceStartup = get_time_static_float("realtimeSinceStartup");
    int targetFrameRate = get_application_static_int("targetFrameRate");
    int vSyncCount = get_quality_static_int("vSyncCount");
    
    if (timeScale >= 0 && fabs(timeScale - g_last_timeScale) > 0.001) {
        writeLog(@"[时间变化] timeScale: %.3f -> %.3f", g_last_timeScale, timeScale);
        g_last_timeScale = timeScale;
    }
    if (maximumDeltaTime >= 0 && fabs(maximumDeltaTime - g_last_maximumDeltaTime) > 0.001) {
        writeLog(@"[时间变化] maximumDeltaTime: %.4f -> %.4f (帧时间上限，决定加速上限) 当前deltaTime=%.4f", g_last_maximumDeltaTime, maximumDeltaTime, deltaTime);
        g_last_maximumDeltaTime = maximumDeltaTime;
    }
    if (targetFrameRate != g_last_targetFrameRate) {
        writeLog(@"[时间变化] targetFrameRate: %d -> %d", g_last_targetFrameRate, targetFrameRate);
        g_last_targetFrameRate = targetFrameRate;
    }
    if (vSyncCount != g_last_vSyncCount) {
        writeLog(@"[时间变化] vSyncCount: %d -> %d", g_last_vSyncCount, vSyncCount);
        g_last_vSyncCount = vSyncCount;
    }
}

#pragma mark - 定时监控
static NSTimer *g_monitor_timer = nil;

static void monitor_timer_callback(NSTimer *timer) {
    @autoreleasepool {
        check_time_changes();
        
        // 每 10 秒输出一次统计
        static int last_output = 0;
        int now = (int)[[NSDate date] timeIntervalSince1970];
        if (now - last_output >= 10) {
            last_output = now;
            float timeScale = get_time_static_float("timeScale");
            float maximumDeltaTime = get_time_static_float("maximumDeltaTime");
            float deltaTime = get_time_static_float("deltaTime");
            float realtimeSinceStartup = get_time_static_float("realtimeSinceStartup");
            int targetFrameRate = get_application_static_int("targetFrameRate");
            int vSyncCount = get_quality_static_int("vSyncCount");
            
            writeLog(@"[状态快照] timeScale=%.3f, maxDeltaTime=%.4f, deltaTime=%.4f, realtime=%.1f, targetFPS=%d, vSync=%d, 理论加速上限=%.1fx",
                     timeScale, maximumDeltaTime, deltaTime, realtimeSinceStartup, targetFrameRate, vSyncCount,
                     (maximumDeltaTime > 0 && deltaTime > 0) ? maximumDeltaTime / deltaTime : 0);
            
            // 不 hook il2cpp_runtime_invoke，无调用统计
        }
    }
}

#pragma mark - 悬浮按钮
@interface TracerFloatingButton : UIWindow
@property (nonatomic, strong) UIButton *button;
@end

@implementation TracerFloatingButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.windowLevel = UIWindowLevelAlert + 1000;
        self.backgroundColor = [UIColor clearColor];
        self.hidden = NO;
        
        self.button = [UIButton buttonWithType:UIButtonTypeCustom];
        self.button.frame = CGRectMake(0, 0, 60, 60);
        self.button.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9];
        self.button.layer.cornerRadius = 30;
        self.button.clipsToBounds = YES;
        [self.button setTitle:@"抓" forState:UIControlStateNormal];
        self.button.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [self.button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.button addTarget:self action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.button];
        
        // 可拖动
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self.button addGestureRecognizer:pan];
    }
    return self;
}

- (void)buttonTapped {
    @try {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"GameTracer 抓取工具" message:@"选择操作" preferredStyle:UIAlertControllerStyleActionSheet];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"导出日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self exportLog];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"清空日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self clearLog];
        }]];
        
        NSString *toggleTitle = g_tracer_enabled ? @"暂停抓取" : @"开启抓取";
        [alert addAction:[UIAlertAction actionWithTitle:toggleTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self toggleTracer];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"关闭悬浮球" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self closeTracer];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        
        // iPad 适配
        alert.popoverPresentationController.sourceView = self.button;
        alert.popoverPresentationController.sourceRect = self.button.bounds;
        
        UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
        [root presentViewController:alert animated:YES completion:nil];
    } @catch (NSException *e) {
        NSLog(@"GameTracer buttonTapped exception: %@", e);
    }
}

- (void)exportLog {
    @try {
        NSString *path = logFilePath();
        NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!content || content.length == 0) content = @"日志为空";
        
        UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[content] applicationActivities:nil];
        vc.popoverPresentationController.sourceView = self.button;
        UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
        [root presentViewController:vc animated:YES completion:nil];
        writeLog(@"用户导出日志");
    } @catch (NSException *e) {
        NSLog(@"GameTracer exportLog exception: %@", e);
    }
}

- (void)clearLog {
    @try {
        NSString *path = logFilePath();
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        g_method_call_count = [NSMutableDictionary dictionary];
        g_invoke_count = 0;
        writeLog(@"日志已清空");
    } @catch (NSException *e) {
        NSLog(@"GameTracer clearLog exception: %@", e);
    }
}

- (void)toggleTracer {
    @try {
        g_tracer_enabled = !g_tracer_enabled;
        writeLog(@"抓取状态: %@", g_tracer_enabled ? @"开启" : @"暂停");
    } @catch (NSException *e) {
        NSLog(@"GameTracer toggleTracer exception: %@", e);
    }
}

- (void)closeTracer {
    @try {
        g_tracer_enabled = NO;
        self.hidden = YES;
    } @catch (NSException *e) {
        NSLog(@"GameTracer closeTracer exception: %@", e);
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    newCenter.x = MAX(30, MIN(screenSize.width - 30, newCenter.x));
    newCenter.y = MAX(30, MIN(screenSize.height - 30, newCenter.y));
    
    self.center = newCenter;
    [pan setTranslation:CGPointZero inView:self];
}

@end

#pragma mark - 初始化
static TracerFloatingButton *g_floating_button = nil;
static BOOL g_initialized = NO;

static void do_initialize(void) {
    if (g_initialized) return;
    g_initialized = YES;
    
    @try {
        // 先缓存所有 IL2CPP 函数指针（避免每次 dlsym）
        cache_il2cpp_funcs();
        
        g_method_call_count = [NSMutableDictionary dictionary];
        g_time_changes = [NSMutableArray array];
        
        writeLog(@"GameTracer 插件加载（延迟初始化+函数指针缓存）");
        
        // 查找 IL2CPP 镜像
        if (g_domain_get && g_domain_get_assemblies && g_assembly_get_image && g_class_from_name) {
            void *domain = g_domain_get();
            size_t asm_count = 0;
            void **assemblies = g_domain_get_assemblies(domain, &asm_count);
            writeLog(@"找到 %zu 个程序集", asm_count);
            
            for (size_t i = 0; i < asm_count; i++) {
                void *image = g_assembly_get_image(assemblies[i]);
                if (image) {
                    void *timeClass = g_class_from_name(image, "UnityEngine", "Time");
                    if (timeClass) {
                        il2cpp_image = image;
                        writeLog(@"找到 Unity 镜像，Time 类在程序集 %zu", i);
                        break;
                    }
                }
            }
        }
        
        // 不 hook il2cpp_runtime_invoke（避免反作弊检测导致崩溃），只靠定时轮询获取时间属性
        writeLog(@"使用定时轮询模式，不 hook il2cpp_runtime_invoke");
        
        // 启动定时监控（用递归 dispatch_after，避免 NSTimer 的 unrecognized selector 崩溃）
        static BOOL timerRunning = NO;
        if (!timerRunning) {
            timerRunning = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                __block void (^timerBlock)(void);
                timerBlock = ^{
                    if (!g_tracer_enabled) { timerRunning = NO; return; }
                    @try {
                        monitor_timer_callback(nil);
                    } @catch (NSException *e) {
                        NSLog(@"GameTracer timer exception: %@", e);
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), timerBlock);
                };
                timerBlock();
            });
        }
        
        // 显示悬浮按钮
        CGSize screenSize = [UIScreen mainScreen].bounds.size;
        g_floating_button = [[TracerFloatingButton alloc] initWithFrame:CGRectMake(screenSize.width - 80, 200, 60, 60)];
        [g_floating_button makeKeyAndVisible];
        
        writeLog(@"GameTracer 初始化完成，悬浮按钮已显示");
        
        // 初始状态快照
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            check_time_changes();
            float timeScale = get_time_static_float("timeScale");
            float maximumDeltaTime = get_time_static_float("maximumDeltaTime");
            int targetFrameRate = get_application_static_int("targetFrameRate");
            int vSyncCount = get_quality_static_int("vSyncCount");
            writeLog(@"[初始状态] timeScale=%.3f, maxDeltaTime=%.4f, targetFPS=%d, vSync=%d", timeScale, maximumDeltaTime, targetFrameRate, vSyncCount);
        });
        
    } @catch (NSException *e) {
        NSLog(@"GameTracer 初始化异常: %@", e);
        writeLog(@"初始化异常: %@", e);
    }
}

static void __attribute__((constructor)) initialize(void) {
    @autoreleasepool {
        // 延迟到游戏启动完成后再初始化，避免启动看门狗超时
        // 监听 UIApplicationDidFinishLaunchingNotification，启动完成后 5 秒再初始化
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                do_initialize();
            });
        }];
        
        // 兜底：如果 15 秒后还没初始化（可能没有收到启动通知），直接初始化
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            do_initialize();
        });
    }
}
