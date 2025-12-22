type CacheEntry<T> = {
    value: T;
    /** Expiration timestamp in milliseconds */
    expiry: number;
};

/**
 * A simple in-memory cache with Time-To-Live (TTL) functionality.
 */
export class TTLCache<K, V> {
    private cache = new Map<K, CacheEntry<V>>();

    /**
     * Sets a value in the cache with a specific Time-To-Live (TTL).
     * @param key The key under which to store the value.
     * @param value The value to store.
     * @param ttlSeconds The time-to-live for the entry in seconds.
     */
    public set(key: K, value: V, ttlSeconds: number): void {
        if (ttlSeconds <= 0) {
            this.cache.set(key, { value, expiry: Infinity });
            return;
        }

        const ttlMilliseconds = ttlSeconds * 1000;
        const expiry = Date.now() + ttlMilliseconds;

        this.cache.set(key, { value, expiry });
    }

    /**
     * Retrieves a value from the cache. If the entry has expired, it is removed
     * and `undefined` is returned.
     * @param key The key of the value to retrieve.
     * @returns The stored value, or `undefined` if the key is not found or the entry has expired.
     */
    public get(key: K): V | undefined {
        const entry = this.cache.get(key);

        if (!entry) {
            return undefined;
        }

        if (entry.expiry < Date.now()) {
            // Entry is expired, remove it and return undefined
            this.cache.delete(key);
            return undefined;
        }

        // Entry is valid, return the value
        return entry.value;
    }

    public map(): Map<K, CacheEntry<V>> {
        return this.cache;
    }

    /**
     * Checks if a key exists and has not expired.
     * @param key The key to check.
     * @returns `true` if the key exists and is still valid, `false` otherwise.
     */
    public has(key: K): boolean {
        // Calling get will also handle the expiration check
        return this.get(key) !== undefined;
    }

    /**
     * Removes an entry from the cache.
     * @param key The key of the entry to remove.
     */
    public delete(key: K): boolean {
        return this.cache.delete(key);
    }

    /**
     * Clears all entries from the cache.
     */
    public clear(): void {
        this.cache.clear();
    }

    /**
     * Returns the current number of valid (non-expired) items in the cache.
     * Note: This will perform a check for all items to ensure accuracy.
     */
    public size(): number {
        let count = 0;
        for (const key of this.cache.keys()) {
            if (this.has(key)) {
                count++;
            }
        }
        return count;
    }

    /**
     * Asynchronously prunes expired items from the cache.
     * Yields to the event loop every `chunkSize` items to avoid blocking.
     */
    public async prune(chunkSize = 1000): Promise<void> {
        let checked = 0;
        // Create a copy of keys to avoid modification issues during iteration, 
        // though Map iteration handles deletion well, strictly speaking.
        for (const key of this.cache.keys()) {
            // has() triggers get() which triggers expiry check/cleanup
            this.has(key);
            
            checked++;
            if (checked % chunkSize === 0) {
                await new Promise(resolve => setTimeout(resolve, 0));
            }
        }
    }
}
