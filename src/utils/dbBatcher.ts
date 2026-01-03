import { CacheModel } from "../models/MemoryCache";

class DbBatcher {
    private queue: any[] = [];
    private timer: NodeJS.Timeout | null = null;
    private readonly BATCH_SIZE = 500;
    private readonly FLUSH_INTERVAL_MS = 5000; // 5 seconds

    constructor() {
        this.start();
    }

    public add(op: any) {
        this.queue.push(op);
        if (this.queue.length >= this.BATCH_SIZE) {
            this.flush();
        }
    }

    public addMany(ops: any[]) {
        this.queue.push(...ops);
        if (this.queue.length >= this.BATCH_SIZE) {
            this.flush();
        }
    }

    private start() {
        // Prevent multiple timers
        if (this.timer) clearInterval(this.timer);
        
        this.timer = setInterval(() => {
            if (this.queue.length > 0) {
                this.flush();
            }
        }, this.FLUSH_INTERVAL_MS);
    }

    private async flush() {
        if (this.queue.length === 0) return;

        // Snapshot and clear queue immediately to unblock new writes
        const ops = this.queue;
        this.queue = [];

        try {
            await CacheModel.bulkWrite(ops, { ordered: false });
        } catch (err) {
            console.error(`[DbBatcher] Failed to flush ${ops.length} items:`, err);
            // In a production environment, you might want to retry specific failed ops
            // or log them to a dead-letter queue.
        }
    }
}

export const dbBatcher = new DbBatcher();
