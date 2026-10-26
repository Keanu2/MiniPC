#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/capability.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>
#include <neural_network_runtime/neural_network_runtime.h>

static int add_probe(void *h, size_t id) {
#define API(f) __typeof__(&f) p_##f = dlsym(h, #f); if (!p_##f) { printf("missing=%s\n", #f); return 2; }
    API(OH_NNModel_Construct) API(OH_NNModel_AddTensor) API(OH_NNModel_SetTensorData)
    API(OH_NNModel_AddOperation) API(OH_NNModel_SpecifyInputsAndOutputs) API(OH_NNModel_Finish)
    API(OH_NNCompilation_Construct) API(OH_NNCompilation_SetDevice) API(OH_NNCompilation_Build)
    API(OH_NNExecutor_Construct) API(OH_NNExecutor_SetInput) API(OH_NNExecutor_SetOutput) API(OH_NNExecutor_Run)
    API(OH_NNExecutor_Destroy) API(OH_NNCompilation_Destroy) API(OH_NNModel_Destroy)
#undef API
    OH_NNModel *model = p_OH_NNModel_Construct();
    OH_NNCompilation *compilation = NULL;
    OH_NNExecutor *executor = NULL;
    int rc = -1;
    if (!model) return 3;
    int32_t dims[] = {1, 1, 1, 2}, scalar[] = {1};
    OH_NN_Tensor tensor = {OH_NN_FLOAT32, 4, dims, NULL, OH_NN_TENSOR};
    OH_NN_Tensor activation = {OH_NN_INT8, 1, scalar, NULL, OH_NN_ADD_ACTIVATIONTYPE};
    int8_t noActivation = 0;
    uint32_t inIds[] = {0, 1}, outIds[] = {2}, paramIds[] = {3};
    OH_NN_UInt32Array inputs = {inIds, 2}, outputs = {outIds, 1}, params = {paramIds, 1};
    float a[] = {1, 2}, b[] = {3, 4}, output[] = {0, 0};
#define CHECK(f, ...) do { rc = p_##f(__VA_ARGS__); printf("ADD %s rc=%d\n", #f, rc); if (rc != OH_NN_SUCCESS) goto done; } while (0)
    for (int i = 0; i < 3; i++) CHECK(OH_NNModel_AddTensor, model, &tensor);
    CHECK(OH_NNModel_AddTensor, model, &activation);
    CHECK(OH_NNModel_SetTensorData, model, 3, &noActivation, sizeof(noActivation));
    CHECK(OH_NNModel_AddOperation, model, OH_NN_OPS_ADD, &params, &inputs, &outputs);
    CHECK(OH_NNModel_SpecifyInputsAndOutputs, model, &inputs, &outputs);
    CHECK(OH_NNModel_Finish, model);
    compilation = p_OH_NNCompilation_Construct(model);
    if (!compilation) { rc = -1; goto done; }
    CHECK(OH_NNCompilation_SetDevice, compilation, id);
    CHECK(OH_NNCompilation_Build, compilation);
    executor = p_OH_NNExecutor_Construct(compilation);
    if (!executor) { rc = -2; goto done; }
    CHECK(OH_NNExecutor_SetInput, executor, 0, &tensor, a, sizeof(a));
    CHECK(OH_NNExecutor_SetInput, executor, 1, &tensor, b, sizeof(b));
    CHECK(OH_NNExecutor_SetOutput, executor, 0, output, sizeof(output));
    CHECK(OH_NNExecutor_Run, executor);
    printf("ADD output=%.3f,%.3f expected=4,6\n", output[0], output[1]);
    rc = output[0] == 4 && output[1] == 6 ? 0 : -3;
done:
    if (executor) p_OH_NNExecutor_Destroy(&executor);
    if (compilation) p_OH_NNCompilation_Destroy(&compilation);
    p_OH_NNModel_Destroy(&model);
    printf("ADD finished rc=%d\n", rc);
    return rc;
#undef CHECK
}

static void identity(void) {
    char domain[128] = {0};
    int fd = open("/proc/self/attr/current", O_RDONLY);
    if (fd >= 0) { read(fd, domain, sizeof(domain) - 1); close(fd); }
    printf("uid=%u gid=%u domain=%s\n", getuid(), getgid(), domain);
    gid_t groups[32]; int n = getgroups(32, groups);
    printf("groups="); for (int i = 0; i < n; i++) printf("%u,", groups[i]); puts("");
}
static void *library(const char *path) {
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    printf("library=%s loaded=%d error=%s\n", path, h != NULL, h ? "" : dlerror());
    return h;
}
int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    alarm(25);
    if (argc != 2 && argc != 3) return 2;
    if (argc == 3 && strcmp(argv[2], "--add") != 0) return 2;
    unsigned passed = 0;
    char *end = NULL;
    unsigned long uid = strtoul(argv[1], &end, 10);
    if (!end || *end || uid < 20000000 || uid >= 30000000) return 2;
    if (getuid() == 0) {
        const gid_t groups[] = {1097, 3099};
        if (setgroups(2, groups) || setgid(uid) || setuid(uid)) return 3;
    }
    struct __user_cap_header_struct header = {_LINUX_CAPABILITY_VERSION_3, 0};
    struct __user_cap_data_struct caps[2] = {{0}};
    if (syscall(SYS_capset, &header, caps) || getuid() != uid) return 3;
    identity();
    puts("NOTE: HDC security domain/token remain different from a HAP. This is API discovery, not an application inference test.");
    const char *nodes[] = {"/dev/dma_heap/system_heap", "/dev/npu0"};
    for (unsigned i = 0; i < 2; i++) {
        errno = 0; int fd = open(nodes[i], O_RDWR | O_CLOEXEC);
        printf("driver=%s fd=%d errno=%d\n", nodes[i], fd, errno);
        if (fd >= 0) close(fd);
    }
    void *foundation = library("/system/lib64/ndk/libhiai_foundation.so");
    if (foundation) {
        const char *(*version)(void) = dlsym(foundation, "HMS_HiAI_GetVersion");
        const char *v = version ? version() : NULL;
        printf("HMS_HiAI_GetVersion=%s\n", v ? v : "unavailable");
        const char *names[] = {"HMS_LLMEngineContext_CreateFromContextJson", "HMS_LLMEngineExecutor_CreateFromExecutorJson",
            "HMS_LLMEnginePrompt_Create", "HMS_LLMEngineExecutor_Generate", "HMS_LLMEnginePrompt_SetText"};
        for (unsigned i = 0; i < sizeof(names)/sizeof(names[0]); i++) printf("public=%s present=%d\n", names[i], dlsym(foundation, names[i]) != NULL);
    }
    void *nnrt = library("/system/lib64/ndk/libneural_network_runtime.so");
    if (nnrt) {
        OH_NN_ReturnCode (*all)(const size_t **, uint32_t *) = dlsym(nnrt, "OH_NNDevice_GetAllDevicesID");
        OH_NN_ReturnCode (*name)(size_t, const char **) = dlsym(nnrt, "OH_NNDevice_GetName");
        OH_NN_ReturnCode (*type)(size_t, OH_NN_DeviceType *) = dlsym(nnrt, "OH_NNDevice_GetType");
        if (all && name && type) {
            const size_t *ids = NULL; uint32_t count = 0;
            int rc = all(&ids, &count);
            printf("NNRT device query rc=%d count=%u\n", rc, count);
            if (rc == OH_NN_SUCCESS && ids) for (unsigned i = 0; i < count && i < 16; i++) {
                const char *n = NULL; OH_NN_DeviceType t = OH_NN_OTHERS;
                int nr = name(ids[i], &n), tr = type(ids[i], &t);
                printf("NNRT device id=%zu name=%s name_rc=%d type=%d type_rc=%d\n", ids[i], n ? n : "?", nr, t, tr);
                if (argc == 3 && add_probe(nnrt, ids[i]) == 0) ++passed;
            }
        }
    }
    // This short-lived discovery executable has no HAP lifecycle. The vendor
    // libraries faulted during process-wide exit cleanup in the first run.
    // Do not treat discovery as lifecycle validation; model objects above are
    // explicitly destroyed, then the diagnostic exits without static cleanup.
    printf("API discovery complete; ADD backends passed=%u; HAP inference and lifecycle are not validated.\n", passed);
    _exit(argc == 3 && !passed ? 1 : 0);
}
