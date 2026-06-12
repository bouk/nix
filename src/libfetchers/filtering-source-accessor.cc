#include "nix/fetchers/filtering-source-accessor.hh"
#include "nix/util/sync.hh"

#include <boost/unordered/concurrent_flat_set.hpp>
#include <boost/unordered/unordered_flat_set.hpp>

namespace nix {

std::optional<std::filesystem::path> FilteringSourceAccessor::getPhysicalPath(const CanonPath & path)
{
    checkAccess(path);
    return next->getPhysicalPath(prefix / path);
}

void FilteringSourceAccessor::readFile(const CanonPath & path, Sink & sink, fun<void(uint64_t)> sizeCallback)
{
    checkAccess(path);
    return next->readFile(prefix / path, sink, sizeCallback);
}

bool FilteringSourceAccessor::pathExists(const CanonPath & path)
{
    return isAllowed(path) && next->pathExists(prefix / path);
}

std::optional<SourceAccessor::Stat> FilteringSourceAccessor::maybeLstat(const CanonPath & path)
{
    return isAllowed(path) ? next->maybeLstat(prefix / path) : std::nullopt;
}

SourceAccessor::Stat FilteringSourceAccessor::lstat(const CanonPath & path)
{
    checkAccess(path);
    return next->lstat(prefix / path);
}

SourceAccessor::DirEntries FilteringSourceAccessor::readDirectory(const CanonPath & path)
{
    checkAccess(path);
    DirEntries entries;
    for (auto & entry : next->readDirectory(prefix / path)) {
        if (isAllowed(path / entry.first))
            entries.insert(std::move(entry));
    }
    return entries;
}

std::string FilteringSourceAccessor::readLink(const CanonPath & path)
{
    checkAccess(path);
    return next->readLink(prefix / path);
}

std::string FilteringSourceAccessor::showPath(const CanonPath & path)
{
    return displayPrefix + next->showPath(prefix / path) + displaySuffix;
}

std::pair<CanonPath, std::optional<std::string>> FilteringSourceAccessor::getFingerprint(const CanonPath & path)
{
    if (fingerprint)
        return {path, fingerprint};
    return next->getFingerprint(prefix / path);
}

void FilteringSourceAccessor::checkAccess(const CanonPath & path)
{
    if (!isAllowed(path))
        throw makeNotAllowedError(path);
}

struct AllowListSourceAccessorImpl : AllowListSourceAccessor
{
private:
    void anchor() override {};

    struct Prefixes
    {
        /**
         * Ordered, for checking whether a path is an ancestor of an
         * allowed prefix (and thus traversable).
         */
        std::set<CanonPath> ordered;

        /**
         * The same prefixes, for O(1) per-ancestor lookups.
         */
        boost::unordered_flat_set<CanonPath> byPath;
    };

public:
    SharedSync<Prefixes> allowedPrefixes;
    boost::concurrent_flat_set<CanonPath> allowedPaths;

    AllowListSourceAccessorImpl(
        ref<SourceAccessor> next,
        const std::set<CanonPath> & allowedPrefixes,
        const std::unordered_set<CanonPath> & allowedPaths,
        MakeNotAllowedError && makeNotAllowedError)
        : AllowListSourceAccessor(SourcePath(next), std::move(makeNotAllowedError))
        , allowedPrefixes(Prefixes{
              .ordered = allowedPrefixes,
              .byPath = {allowedPrefixes.begin(), allowedPrefixes.end()},
          })
        , allowedPaths(allowedPaths.begin(), allowedPaths.end())
    {
    }

    bool isAllowed(const CanonPath & path) override
    {
        if (allowedPaths.contains(path))
            return true;

        bool allowed = [&] {
            auto prefixes = allowedPrefixes.readLock();

            /* Mirrors CanonPath::isAllowed, but checks ancestors against a
               hash set instead of walking the ordered set per level. */
            if (prefixes->byPath.contains(path))
                return true;

            /* Check if `path` is an exact match or the parent of an
               allowed prefix. */
            auto lb = prefixes->ordered.lower_bound(path);
            if (lb != prefixes->ordered.end() && lb->isWithin(path))
                return true;

            /* Check if a parent of `path` is allowed. */
            auto parent = path;
            while (!parent.isRoot()) {
                parent.pop();
                if (prefixes->byPath.contains(parent))
                    return true;
            }

            return false;
        }();

        if (allowed) {
            /* Memoise the verdict; repeated accesses then short-circuit on
               the concurrent set. Only positive results are cached since
               allowPrefix can extend the allowed set. */
            allowedPaths.insert(path);
            return true;
        }
        return false;
    }

    void allowPrefix(CanonPath prefix) override
    {
        auto prefixes = allowedPrefixes.lock();
        prefixes->ordered.insert(prefix);
        prefixes->byPath.insert(std::move(prefix));
    }
};

ref<AllowListSourceAccessor> AllowListSourceAccessor::create(
    ref<SourceAccessor> next,
    const std::set<CanonPath> & allowedPrefixes,
    const std::unordered_set<CanonPath> & allowedPaths,
    MakeNotAllowedError && makeNotAllowedError)
{
    return make_ref<AllowListSourceAccessorImpl>(next, allowedPrefixes, allowedPaths, std::move(makeNotAllowedError));
}

bool CachingFilteringSourceAccessor::isAllowed(const CanonPath & path)
{
    auto i = cache.find(path);
    if (i != cache.end())
        return i->second;
    auto res = isAllowedUncached(path);
    cache.emplace(path, res);
    return res;
}

} // namespace nix
