// Stored calls in C++, three idiomatic ways, with the same work, input and
// checksum as goose/calls_deferred.goose (bench/deferred/README.md):
//
//   calls_cpp <function|virtual|variant> <n> <passes>
//     -> build_ns run_ns checksum bytes_per_call
//
// function: std::vector<std::function<uint64_t(uint64_t)>> of lambdas, each
//           capturing its arguments (small enough for the in-object buffer);
// virtual:  std::vector<std::unique_ptr<Op>> of four classes;
// variant:  std::vector<std::variant<...>> with std::visit.
// bytes_per_call is the element's own size, plus the heap block a virtual
// call's object takes (malloc_size, rounded as the allocator rounds).
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <variant>
#include <vector>
#ifdef __APPLE__
#include <malloc/malloc.h>
#endif

static uint64_t xs_next(uint64_t v) {
    v ^= v << 13;
    v ^= v >> 7;
    v ^= v << 17;
    return v;
}

static int64_t now_ns() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch()).count();
}

static uint64_t rotl(uint64_t x, uint8_t n) { return (x << n) | (x >> (64 - n)); }

// Calls the four kinds in the order every implementation generates them.
template <typename Add, typename Mul, typename Mix, typename Rot>
static void generate(int64_t n, Add add, Mul mul, Mix mix, Rot rot) {
    uint64_t r = 88172645463325252ull;
    for (int64_t i = 0; i < n; i++) {
        r = xs_next(r);
        uint64_t k = r % 4, v = r >> 8;
        if (k == 0) add(v);
        else if (k == 1) mul(v | 1);
        else if (k == 2) mix((uint32_t)v, (uint32_t)(v >> 32));
        else rot((uint8_t)(v % 63 + 1));
    }
}

struct Op {
    virtual ~Op() = default;
    virtual uint64_t call(uint64_t x) const = 0;
};
struct AddOp : Op { uint64_t k; explicit AddOp(uint64_t k) : k(k) {} uint64_t call(uint64_t x) const override { return x + k; } };
struct MulOp : Op { uint64_t k; explicit MulOp(uint64_t k) : k(k) {} uint64_t call(uint64_t x) const override { return x * k; } };
struct MixOp : Op { uint32_t a, b; MixOp(uint32_t a, uint32_t b) : a(a), b(b) {} uint64_t call(uint64_t x) const override { return (x ^ a) + b; } };
struct RotOp : Op { uint8_t n; explicit RotOp(uint8_t n) : n(n) {} uint64_t call(uint64_t x) const override { return rotl(x, n); } };

struct VAdd { uint64_t k; };
struct VMul { uint64_t k; };
struct VMix { uint32_t a, b; };
struct VRot { uint8_t n; };
using VOp = std::variant<VAdd, VMul, VMix, VRot>;
struct Apply {
    uint64_t x;
    uint64_t operator()(const VAdd &o) const { return x + o.k; }
    uint64_t operator()(const VMul &o) const { return x * o.k; }
    uint64_t operator()(const VMix &o) const { return (x ^ o.a) + o.b; }
    uint64_t operator()(const VRot &o) const { return rotl(x, o.n); }
};

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: calls_cpp <function|virtual|variant> <n> <passes>\n"); return 2; }
    const char *mode = argv[1];
    int64_t n = atoll(argv[2]), passes = atoll(argv[3]);
    int64_t t0, t1, t2;
    uint64_t x = 1;
    size_t bytes = 0;
    if (!strcmp(mode, "function")) {
        std::vector<std::function<uint64_t(uint64_t)>> ops;
        t0 = now_ns();
        generate(n,
            [&](uint64_t k) { ops.push_back([k](uint64_t x) { return x + k; }); },
            [&](uint64_t k) { ops.push_back([k](uint64_t x) { return x * k; }); },
            [&](uint32_t a, uint32_t b) { ops.push_back([a, b](uint64_t x) { return (x ^ a) + b; }); },
            [&](uint8_t r) { ops.push_back([r](uint64_t x) { return rotl(x, r); }); });
        t1 = now_ns();
        for (int64_t p = 0; p < passes; p++)
            for (auto &f : ops) x = f(x);
        t2 = now_ns();
        bytes = sizeof(ops[0]);
    } else if (!strcmp(mode, "virtual")) {
        std::vector<std::unique_ptr<Op>> ops;
        t0 = now_ns();
        generate(n,
            [&](uint64_t k) { ops.push_back(std::make_unique<AddOp>(k)); },
            [&](uint64_t k) { ops.push_back(std::make_unique<MulOp>(k)); },
            [&](uint32_t a, uint32_t b) { ops.push_back(std::make_unique<MixOp>(a, b)); },
            [&](uint8_t r) { ops.push_back(std::make_unique<RotOp>(r)); });
        t1 = now_ns();
        for (int64_t p = 0; p < passes; p++)
            for (auto &o : ops) x = o->call(x);
        t2 = now_ns();
        size_t heap = 0;
#ifdef __APPLE__
        for (auto &o : ops) heap += malloc_size(o.get());
#else
        for (auto &o : ops) heap += 16;
#endif
        bytes = sizeof(ops[0]) + (n ? heap / (size_t)n : 0);
    } else if (!strcmp(mode, "variant")) {
        std::vector<VOp> ops;
        t0 = now_ns();
        generate(n,
            [&](uint64_t k) { ops.push_back(VAdd{k}); },
            [&](uint64_t k) { ops.push_back(VMul{k}); },
            [&](uint32_t a, uint32_t b) { ops.push_back(VMix{a, b}); },
            [&](uint8_t r) { ops.push_back(VRot{r}); });
        t1 = now_ns();
        for (int64_t p = 0; p < passes; p++)
            for (auto &o : ops) x = std::visit(Apply{x}, o);
        t2 = now_ns();
        bytes = sizeof(ops[0]);
    } else {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }
    printf("%lld %lld %llu %zu\n", (long long)(t1 - t0), (long long)(t2 - t1),
           (unsigned long long)x, bytes);
    return 0;
}
