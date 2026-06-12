#include "nix/expr/attr-set.hh"
#include "nix/expr/eval-inline.hh"

#include <algorithm>

namespace nix {

Bindings Bindings::emptyBindings;

/* Allocate a new array of attributes for an attribute set with a specific
   capacity. The space is implicitly reserved after the Bindings
   structure. */
Bindings * EvalMemory::allocBindings(size_t capacity)
{
    if (capacity == 0)
        return &Bindings::emptyBindings;
    if (capacity > std::numeric_limits<Bindings::size_type>::max())
        throw Error("attribute set of size %d is too big", capacity);
    stats.nrAttrsets++;
    stats.nrAttrsInAttrsets += capacity;

    void * p;
#if NIX_USE_BOEHMGC
    /* Batch the allocation of small Bindings the same way Values and Envs
       are batched; small attribute sets are allocated millions of times
       during e.g. NixOS evaluation. */
    constexpr size_t maxBatchedCapacity = 8;
    if (capacity <= maxBatchedCapacity) {
        using BindingsCacheArray = std::array<void *, maxBatchedCapacity>;
        static thread_local std::shared_ptr<BindingsCacheArray> bindingsAllocCaches{
            std::allocate_shared<BindingsCacheArray>(traceable_allocator<BindingsCacheArray>(), BindingsCacheArray{})};

        void *& cache = (*bindingsAllocCaches)[capacity - 1];
        /* see EvalMemory::allocValue for explanations. */
        if (!cache) {
            cache = GC_malloc_many(sizeof(Bindings) + sizeof(Attr) * capacity);
            if (!cache)
                throw std::bad_alloc();
        }

        p = cache;
        cache = GC_NEXT(p);
        GC_NEXT(p) = nullptr;
    } else
#endif
        p = allocBytes(sizeof(Bindings) + sizeof(Attr) * capacity);

    return new (p) Bindings();
}

Value & BindingsBuilder::alloc(Symbol name, PosIdx pos)
{
    auto value = mem.get().allocValue();
    bindings->push_back(Attr(name, value, pos));
    return *value;
}

Value & BindingsBuilder::alloc(std::string_view name, PosIdx pos)
{
    return alloc(symbols.get().create(name), pos);
}

void Bindings::sort()
{
    std::sort(attrs, attrs + numAttrs);
}

Value & Value::mkAttrs(BindingsBuilder & bindings)
{
    mkAttrs(bindings.finish());
    return *this;
}

} // namespace nix
