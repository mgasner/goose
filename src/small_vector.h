// Goose compiler — small_vector: a vector that keeps its first N elements in
// place and only takes heap storage past that, for the short lists the
// checker creates, copies and drops by the million (a value's Roots, a flow
// snapshot's variables). Elements are trivially copyable, so growing and
// copying are memcpy. After lobster's small_vector.h.
#pragma once

namespace goose {

template<typename T, int N> class small_vector {
    static_assert(is_trivially_copyable_v<T> && is_trivially_destructible_v<T>);
    static_assert(N > 0);

    uint32_t len = 0;
    uint32_t cap = N;    // Above N: the elements are in buf.
    // The heap pointer overlaps the in-place elements, so N below
    // sizeof(T *) / sizeof(T) saves nothing.
    union {
        alignas(T) unsigned char inl[N * sizeof(T)];
        T *buf;
    };

    bool OnHeap() const { return cap > N; }
    static T *Alloc(uint32_t n) { return allocator<T>().allocate(n); }
    void Free() { if (OnHeap()) allocator<T>().deallocate(buf, cap); }

    // Room for at least n elements, the existing ones kept.
    void Grow(uint32_t n) {
        auto nc = std::max(n, cap * 2);
        auto b = Alloc(nc);
        if (len) memcpy((void *)b, data(), len * sizeof(T));
        Free();
        buf = b;
        cap = nc;
    }
    // Room for at least n elements, the existing ones dropped.
    void Reset(uint32_t n) {
        len = 0;
        if (n <= cap) return;
        Free();
        buf = Alloc(n);
        cap = n;
    }
    // Copies all N in-place slots of o's elements at once, which takes a few
    // moves where a copy of len elements is a call to memcpy. o has room for
    // N elements wherever they are, and those past its len are only bytes.
    void CopyInPlace(const small_vector &o) {
        memcpy(inl, (const void *)o.data(), sizeof(inl));
        len = o.len;
    }
    void CopyFrom(const T *from, uint32_t n) {
        Reset(n);
        if (n) memcpy((void *)data(), from, n * sizeof(T));
        len = n;
    }
    // Takes o's elements, leaving it empty: its heap buffer where it has one,
    // unless ours is big enough already.
    void MoveFrom(small_vector &o) {
        if (o.OnHeap() && o.len > cap) {
            Free();
            buf = o.buf;
            cap = o.cap;
            len = o.len;
            o.cap = N;
        } else {
            CopyFrom(o.data(), o.len);
        }
        o.len = 0;
    }

  public:
    using value_type = T;
    using iterator = T *;
    using const_iterator = const T *;

    small_vector() {}
    small_vector(initializer_list<T> l) { CopyFrom(l.begin(), (uint32_t)l.size()); }
    small_vector(const small_vector &o) {
        if (o.len <= N) CopyInPlace(o);
        else CopyFrom(o.data(), o.len);
    }
    small_vector(small_vector &&o) noexcept {
        if (o.OnHeap()) {
            MoveFrom(o);
        } else {
            CopyInPlace(o);
            o.len = 0;
        }
    }
    ~small_vector() { Free(); }

    small_vector &operator=(const small_vector &o) {
        if (this == &o) return *this;
        if (!OnHeap() && o.len <= N) CopyInPlace(o);
        else CopyFrom(o.data(), o.len);
        return *this;
    }
    small_vector &operator=(small_vector &&o) noexcept {
        if (this == &o) return *this;
        if (!OnHeap() && !o.OnHeap()) {
            CopyInPlace(o);
            o.len = 0;
        } else {
            MoveFrom(o);
        }
        return *this;
    }
    small_vector &operator=(initializer_list<T> l) {
        CopyFrom(l.begin(), (uint32_t)l.size());
        return *this;
    }

    size_t size() const { return len; }
    size_t capacity() const { return cap; }
    bool empty() const { return !len; }
    T *data() { return OnHeap() ? buf : (T *)inl; }
    const T *data() const { return OnHeap() ? buf : (const T *)inl; }

    T *begin() { return data(); }
    T *end() { return data() + len; }
    const T *begin() const { return data(); }
    const T *end() const { return data() + len; }

    T &operator[](size_t i) {
        assert(i < len);
        return data()[i];
    }
    const T &operator[](size_t i) const {
        assert(i < len);
        return data()[i];
    }
    T &front() { return (*this)[0]; }
    const T &front() const { return (*this)[0]; }
    T &back() { return (*this)[len - 1]; }
    const T &back() const { return (*this)[len - 1]; }

    void clear() { len = 0; }
    void reserve(size_t n) { if (n > cap) Grow((uint32_t)n); }
    void resize(size_t n, const T &fill = T()) {
        auto f = fill;   // Which may be one of ours, which growing frees.
        reserve(n);
        for (auto i = len; i < n; i++) new (data() + i) T(f);
        len = (uint32_t)n;
    }

    void push_back(const T &e) {
        if (len == cap) {
            // e may be one of ours, which growing frees.
            auto copy = e;
            Grow(len + 1);
            new (data() + len++) T(copy);
        } else {
            new (data() + len++) T(e);
        }
    }
    template<typename... A> T &emplace_back(A &&...args) {
        push_back(T { std::forward<A>(args)... });
        return back();
    }
    void pop_back() {
        assert(len);
        len--;
    }
    T *insert(const T *pos, const T &e) {
        auto at = (uint32_t)(pos - data());
        assert(at <= len);
        auto copy = e;
        push_back(copy);
        auto d = data();
        memmove((void *)(d + at + 1), d + at, (len - 1 - at) * sizeof(T));
        d[at] = copy;
        return d + at;
    }

    T *erase(const T *first, const T *last) {
        auto d = data();
        auto at = (uint32_t)(first - d), n = (uint32_t)(last - first);
        assert(at + n <= len);
        if (n) memmove((void *)(d + at), d + at + n, (len - at - n) * sizeof(T));
        len -= n;
        return d + at;
    }
    T *erase(const T *pos) { return erase(pos, pos + 1); }

    bool operator==(const small_vector &o) const {
        return std::equal(begin(), end(), o.begin(), o.end());
    }
};

// std::erase_if's counterpart, which ADL finds for these.
template<typename T, int N, typename P> size_t erase_if(small_vector<T, N> &v, P pred) {
    auto it = std::remove_if(v.begin(), v.end(), pred);
    auto n = (size_t)(v.end() - it);
    v.erase(it, v.end());
    return n;
}

}  // namespace goose
