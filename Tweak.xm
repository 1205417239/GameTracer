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
    if (!il2cpp_image) return NULL;
    
    il2cpp_class_from_name_t class_from_name = (il2cpp_class_from_name_t)get_il2cpp_func("il2cpp_class_from_name");
    if (!class_from_name) return NULL;
    
    // 尝试不同的命名空间
    const char *namespaces[] = {"UnityEngine", "", "UnityEngine.CoreModule", NULL};
    for (int i = 0; namespaces[i]; i++) {
        void *klass = class_from_name(il2cpp_image, namespaces[i], name);
        if (klass) return klass;
    }
    return NULL;
}

#pragma mark - 获取 Time 类静态字段值
static float get_time_static_float(const char *fieldName) {
    void *timeClass = find_unity_class("Time");
    if (!timeClass) return -1;
    
    il2cpp_class_get_field_from_name_t get_field = (il2cpp_class_get_field_from_name_t)get_il2cpp_func("il2cpp_class_get_field_from_name");
    il2cpp_field_get_value_t get_value = (il2cpp_field_get_value_t)get_il2cpp_func("il2cpp_field_get_value");
    il2cpp_object_unbox_t unbox = (il2cpp_object_unbox_t)get_il2cpp_func("il2cpp_object_unbox");
    
    if (!get_field || !get_value || !unbox) return -1;
    
    void *field = get_field(timeClass, fieldName);
    if (!field) return -1;
    
    void *value = get_value(NULL, field);
    if (!value) return -1;
    
    float *fval = (float *)unbox(value);
    return fval ? *fval : -1;
}

static int get_application_static_int(const char *fieldName) {
    void *appClass = find_unity_class("Application");
    if (!appClass) return -1;
    
    il2cpp_class_get_field_from_name_t get_field = (il2cpp_class_get_field_from_name_t)get_il2cpp_func("il2cpp_class_get_field_from_name");
    il2cpp_field_get_value_t get_value = (il2cpp_field_get_value_t)get_il2cpp_func("il2cpp_field_get_value");
    il2cpp_object_unbox_t unbox = (il2cpp_object_unbox_t)get_il2cpp_func("il2cpp_object_unbox");
    
    if (!get_field || !get_value || !unbox) return -1;
    
    void *field = get_field(appClass, fieldName);
    if (!field) return -1;
    
    void *value = get_value(NULL, field);
    if (!value) return -1;
    
    int *ival = (int *)unbox(value);
    return ival ? *ival : -1;
}

static int get_quality_static_int(const char *fieldName) {
    void *qClass = find_unity_class("QualitySettings");
    if (!qClass) return -1;
    
    il2cpp_class_get_field_from_name_t get_field = (il2cpp_class_get_field_from_name_t)get_il2cpp_func("il2cpp_class_get_field_from_name");
    il2cpp_field_get_value_t get_value = (il2cpp_field_get_value_t)get_il2cpp_func("il2cpp_field_get_value");
    il2cpp_object_unbox_t unbox = (il2cpp_object_unbox_t)get_il2cpp_func("il2cpp_object_unbox");
    
    if (!get_field || !get_value || !unbox) return -1;
    
    void *field = get_field(qClass, fieldName);
    if (!field) return -1;
    
    void *value = get_value(NULL, field);
    if (!value) return -1;
    
    int *ival = (int *)unbox(value);
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

#pragma mark - hook il2cpp_runtime_invoke
static void* hook_il2cpp_runtime_invoke(void* method, void* obj, void** params, void** exc) {
    if (!g_tracer_enabled || !method) {
        return orig_il2cpp_runtime_invoke(method, obj, params, exc);
    }
    
    // 获取方法名和类名
    il2cpp_method_get_name_t method_get_name = (il2cpp_method_get_name_t)get_il2cpp_func("il2cpp_method_get_name");
    il2cpp_method_get_class_t method_get_class = (il2cpp_method_get_class_t)get_il2cpp_func("il2cpp_method_get_class");
    il2cpp_class_get_name_t class_get_name = (il2cpp_class_get_name_t)get_il2cpp_func("il2cpp_class_get_name");
    il2cpp_class_get_namespace_t class_get_namespace = (il2cpp_class_get_namespace_t)get_il2cpp_func("il2cpp_class_get_namespace");
    
    const char *methodName = method_get_name ? method_get_name(method) : "unknown";
    void *klass = method_get_class ? method_get_class(method) : NULL;
    const char *className = (klass && class_get_name) ? class_get_name(klass) : "unknown";
    const char *nameSpace = (klass && class_get_namespace) ? class_get_namespace(klass) : "";
    
    // 只记录关键类的方法调用
    BOOL isImportant = NO;
    if (strcmp(className, "Time") == 0 ||
        strcmp(className, "Application") == 0 ||
        strcmp(className, "QualitySettings") == 0 ||
        strcmp(className, "Time") == 0 ||
        strstr(methodName, "timeScale") ||
        strstr(methodName, "deltaTime") ||
        strstr(methodName, "maximumDeltaTime") ||
        strstr(methodName, "targetFrameRate") ||
        strstr(methodName, "vSyncCount") ||
        strstr(methodName, "Time") ||
        strstr(methodName, "Speed") ||
        strstr(methodName, "Accelerat")) {
        isImportant = YES;
    }
    
    if (isImportant) {
        g_invoke_count++;
        NSString *key = [NSString stringWithFormat:@"%s.%s", nameSpace, methodName];
        NSNumber *count = g_method_call_count[key];
        g_method_call_count[key] = @([count intValue] + 1);
        
        writeLog(@"[调用] %s.%s (obj=%p, count=%d)", className, methodName, obj, g_invoke_count);
    }
    
    // 执行原函数
    void *result = orig_il2cpp_runtime_invoke(method, obj, params, exc);
    
    // 检查时间属性变化
    if (isImportant && (g_invoke_count % 10 == 0)) {
        check_time_changes();
    }
    
    return result;
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
            int targetFrameRate = get_application_static_int("targetFrameRate");
            int vSyncCount = get_quality_static_int("vSyncCount");
            
            writeLog(@"[状态快照] timeScale=%.3f, maxDeltaTime=%.4f, deltaTime=%.4f, targetFPS=%d, vSync=%d, 理论加速上限=%.1fx",
                     timeScale, maximumDeltaTime, deltaTime, targetFrameRate, vSyncCount,
                     (maximumDeltaTime > 0 && deltaTime > 0) ? maximumDeltaTime / deltaTime : 0);
            
            // 输出调用次数最多的方法
            NSArray *sorted = [g_method_call_count keysSortedByValueUsingComparator:^NSComparisonResult(id obj1, id obj2) {
                return [obj2 compare:obj1];
            }];
            int count = 0;
            for (NSString *key in sorted) {
                if (count >= 10) break;
                writeLog(@"[调用统计] %@: %d次", key, [g_method_call_count[key] intValue]);
                count++;
            }
        }
    }
}

#pragma mark - 悬浮按钮
@interface TracerFloatingButton : UIWindow
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, assign) BOOL isExpanded;
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
    self.isExpanded = !self.isExpanded;
    
    if (self.isExpanded) {
        // 展开菜单
        self.button.frame = CGRectMake(0, 0, 200, 200);
        self.button.layer.cornerRadius = 20;
        
        // 清除所有子视图
        for (UIView *v in self.button.subviews) {
            [v removeFromSuperview];
        }
        
        NSArray *titles = @[@"导出日志", @"清空日志", @"开启/暂停", @"关闭"];
        for (int i = 0; i < titles.count; i++) {
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            btn.frame = CGRectMake(10, 10 + i * 45, 180, 40);
            [btn setTitle:titles[i] forState:UIControlStateNormal];
            btn.backgroundColor = [UIColor whiteColor];
            btn.layer.cornerRadius = 8;
            btn.tag = i;
            [btn addTarget:self action:@selector(menuTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self.button addSubview:btn];
        }
    } else {
        // 收起
        self.button.frame = CGRectMake(0, 0, 60, 60);
        self.button.layer.cornerRadius = 30;
        for (UIView *v in self.button.subviews) {
            [v removeFromSuperview];
        }
        [self.button setTitle:@"抓" forState:UIControlStateNormal];
    }
}

- (void)menuTapped:(UIButton *)sender {
    switch (sender.tag) {
        case 0: { // 导出日志
            NSString *path = logFilePath();
            NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[content ?: @"日志为空"] applicationActivities:nil];
            UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
            [root presentViewController:vc animated:YES completion:nil];
            writeLog(@"用户导出日志");
            break;
        }
        case 1: { // 清空日志
            NSString *path = logFilePath();
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            g_method_call_count = [NSMutableDictionary dictionary];
            g_invoke_count = 0;
            writeLog(@"日志已清空");
            break;
        }
        case 2: { // 开启/暂停
            g_tracer_enabled = !g_tracer_enabled;
            writeLog(@"抓取状态: %@", g_tracer_enabled ? @"开启" : @"暂停");
            break;
        }
        case 3: { // 关闭
            self.hidden = YES;
            [g_monitor_timer invalidate];
            g_monitor_timer = nil;
            break;
        }
    }
    [self buttonTapped]; // 收起菜单
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self];
    CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    
    // 限制在屏幕内
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    newCenter.x = MAX(30, MIN(screenSize.width - 30, newCenter.x));
    newCenter.y = MAX(30, MIN(screenSize.height - 30, newCenter.y));
    
    self.center = newCenter;
    [pan setTranslation:CGPointZero inView:self];
}

@end

#pragma mark - 初始化
static TracerFloatingButton *g_floating_button = nil;

static void __attribute__((constructor)) initialize(void) {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                g_method_call_count = [NSMutableDictionary dictionary];
                g_time_changes = [NSMutableArray array];
                
                writeLog(@"GameTracer 插件加载");
                
                // 查找 IL2CPP 镜像
                il2cpp_domain_get_t domain_get = (il2cpp_domain_get_t)get_il2cpp_func("il2cpp_domain_get");
                il2cpp_domain_get_assemblies_t domain_get_assemblies = (il2cpp_domain_get_assemblies_t)get_il2cpp_func("il2cpp_domain_get_assemblies");
                il2cpp_assembly_get_image_t assembly_get_image = (il2cpp_assembly_get_image_t)get_il2cpp_func("il2cpp_assembly_get_image");
                
                if (domain_get && domain_get_assemblies && assembly_get_image) {
                    void *domain = domain_get();
                    size_t asm_count = 0;
                    void **assemblies = domain_get_assemblies(domain, &asm_count);
                    writeLog(@"找到 %zu 个程序集", asm_count);
                    
                    for (size_t i = 0; i < asm_count; i++) {
                        void *image = assembly_get_image(assemblies[i]);
                        if (image) {
                            // 尝试查找 Time 类
                            il2cpp_class_from_name_t class_from_name = (il2cpp_class_from_name_t)get_il2cpp_func("il2cpp_class_from_name");
                            if (class_from_name) {
                                void *timeClass = class_from_name(image, "UnityEngine", "Time");
                                if (timeClass) {
                                    il2cpp_image = image;
                                    writeLog(@"找到 Unity 镜像，Time 类在程序集 %zu", i);
                                    break;
                                }
                            }
                        }
                    }
                }
                
                // hook il2cpp_runtime_invoke
                orig_il2cpp_runtime_invoke = (il2cpp_runtime_invoke_t)get_il2cpp_func("il2cpp_runtime_invoke");
                if (orig_il2cpp_runtime_invoke) {
                    MSHookFunction((void *)orig_il2cpp_runtime_invoke, (void *)hook_il2cpp_runtime_invoke, (void **)&orig_il2cpp_runtime_invoke);
                    writeLog(@"il2cpp_runtime_invoke hook 成功");
                } else {
                    writeLog(@"未找到 il2cpp_runtime_invoke");
                }
                
                // 启动定时监控
                g_monitor_timer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:[NSObject class] selector:@selector(monitor_timer_callback:) userInfo:nil repeats:YES];
                [[NSRunLoop mainRunLoop] addTimer:g_monitor_timer forMode:NSRunLoopCommonModes];
                
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
            }
        });
    }
}
