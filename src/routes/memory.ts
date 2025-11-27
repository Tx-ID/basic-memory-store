import { Router } from "express";
import type { NextFunction, Request, Response } from "express";
import { ReasonPhrases, StatusCodes } from "http-status-codes";
import * as z from "zod";
import mongoose, { Schema } from "mongoose";
import type { Document } from "mongoose";

import config from "../config/config";
import { TTLCache } from "../utils/cache";

// --- Mongoose Schema & Model ---
interface ICacheDoc extends Document {
    index: string;
    key: string;
    payload: any;
    cursor: number;
    expireAt: Date;
}

const CacheSchema = new Schema<ICacheDoc>({
    index: { type: String, required: true, index: true },
    key: { type: String, required: true, index: true },
    payload: { type: Schema.Types.Mixed, required: true },
    cursor: { type: Number, required: true, index: true },
    expireAt: { type: Date, required: true },
});

CacheSchema.index({ index: 1, key: 1 }, { unique: true });
CacheSchema.index({ expireAt: 1 }, { expireAfterSeconds: 0 }); // MongoDB auto-removes expired docs

const CacheModel = mongoose.model<ICacheDoc>("DynamicCache", CacheSchema);


// --- In-Memory Cache Setup ---
const router = Router();
const cache = new TTLCache<
    string,
    TTLCache<string, { payload: any; cursor: number }>
>();

function get_index_cache(idx: string) {
    let object = cache.get(idx);
    if (!object) {
        object = new TTLCache();
        cache.set(idx, object, 0);
    }
    return object;
}


// Background cleanup for In-Memory cache (every 5 mins)
setInterval(() => {
    // Iterate indices to trigger lazy expiry or perform manual pruning if supported
    for (const idx of cache.map().keys()) {
        const game = cache.get(idx);
        if (game) {
            // If TTLCache requires manual pruning, call it here.
            // Otherwise, accessing keys or iteration usually triggers lazy checks.
            for (const key of game.map().keys()) {
                game.get(key); // Access to trigger lazy expiry if applicable
            }
        }
    }
}, 5 * 60 * 1000);


// --- Validation Schemas ---
const Query = z.object({
    pageSize: z.coerce.number().int().positive().max(5000).default(5000),
    cursor: z.coerce.number().optional(),
    useDb: z.coerce.boolean().default(false), // Toggle DB Read
});

const Body = z.object({
    ttl: z.number().int().default(2 * 60),
    data: z.any(),
    persist: z.boolean().default(false), // Toggle DB Write
});

const isDbReady = () => mongoose.connection.readyState === 1;


// --- Routes ---
async function set(req: Request, res: Response, next: NextFunction) {
    try {
        const index = String(req.params.index!);
        const key = String(req.params.id!);

        const safe = Body.safeParse(req.body);
        if (!safe.success) {
            return res.status(StatusCodes.BAD_REQUEST).send({
                error: ReasonPhrases.BAD_REQUEST,
                error_data: safe.error.issues,
            });
        }

        const { ttl, data, persist } = safe.data;
        const cursor = Date.now();

        if (persist) {
            if (!isDbReady()) {
                return res.status(StatusCodes.SERVICE_UNAVAILABLE).send({ 
                    error: ReasonPhrases.SERVICE_UNAVAILABLE, 
                    message: "Database not connected" 
                });
            }

            const expireAt = new Date(Date.now() + (ttl * 1000));
            await CacheModel.findOneAndUpdate(
                { index, key },
                { payload: data, cursor, expireAt },
                { upsert: true, new: true },
            );
        } else {
            get_index_cache(index).set(key, { payload: data, cursor }, ttl);
        }

        res.status(StatusCodes.OK).send({ message: ReasonPhrases.OK });
    } catch (error) {
        next(error);
    }
}
router.post("/:index/:id", set);

async function del(req: Request, res: Response, next: NextFunction) {
    try {
        const index = String(req.params.index!);
        const key = String(req.params.id!);
        const useDb = req.query.useDb === "true";

        if (useDb) {
            if (!isDbReady()) {
                return res.status(StatusCodes.SERVICE_UNAVAILABLE).send({ 
                    error: ReasonPhrases.SERVICE_UNAVAILABLE, 
                    message: "Database not connected" 
                });
            }

            await CacheModel.deleteOne({ index, key });
        } else {
            get_index_cache(index).delete(key);
        }

        res.status(StatusCodes.OK).send({ message: ReasonPhrases.OK });
    } catch (error) {
        next(error);
    }
}
router.delete("/:index/:id", del);

async function get(req: Request, res: Response, next: NextFunction) {
    try {
        const index = String(req.params.index!);
        const key = String(req.params.id!);
        const useDb = req.query.useDb === "true";

        let data = null;

        if (useDb) {
            if (!isDbReady()) {
                return res.status(StatusCodes.SERVICE_UNAVAILABLE).send({ 
                    error: ReasonPhrases.SERVICE_UNAVAILABLE, 
                    message: "Database not connected" 
                });
            }

            const doc = await CacheModel.findOne({ index, key }).lean();
            if (doc) data = doc.payload;
        } else {
            const entry = get_index_cache(index).get(key);
            if (entry) data = entry.payload;
        }

        res.status(StatusCodes.OK).send({ message: ReasonPhrases.OK, data });
    } catch (error) {
        next(error);
    }
}
router.get("/:index/:id", get);

async function getAll(req: Request, res: Response, next: NextFunction) {
    try {
        const index = String(req.params.index!);
        const safe = Query.safeParse(req.query);
        if (!safe.success) {
            return res.status(StatusCodes.BAD_REQUEST).send({
                error: ReasonPhrases.BAD_REQUEST,
                error_data: safe.error.issues,
            });
        }

        const { cursor, pageSize, useDb } = safe.data;
        let paginatedItems: any[] = [];
        let nextCursor: number | null = null;
        let hasMore = false;
        let totalItems = 0;

        if (useDb) {
            if (!isDbReady()) {
                return res.status(StatusCodes.SERVICE_UNAVAILABLE).send({ 
                    error: ReasonPhrases.SERVICE_UNAVAILABLE, 
                    message: "Database not connected" 
                });
            }

            const q: any = { index };
            if (cursor) q.cursor = { $lt: cursor };

            const docs = await CacheModel.find(q).sort({ cursor: -1 }).limit(
                pageSize,
            ).lean();

            // Note: Counting all docs is expensive; use estimate or careful indexing in prod
            totalItems = await CacheModel.countDocuments({ index });

            paginatedItems = docs.map((d) => ({ key: d.key, data: d.payload }));

            if (docs.length > 0) {
                const last = docs[docs.length - 1]!;
                nextCursor = last.cursor;
                const rem = await CacheModel.findOne({
                    index,
                    cursor: { $lt: nextCursor },
                }).select("_id");
                hasMore = !!rem;
            }
        } else {
            const game = get_index_cache(index);
            const allEntries = [];

            for (const key of game.map().keys()) {
                const entry = game.get(key);
                if (entry) {
                    allEntries.push({
                        key,
                        data: entry.payload,
                        cursor: entry.cursor,
                    });
                }
            }

            let sorted = allEntries.sort((a, b) => b.cursor - a.cursor);
            totalItems = sorted.length;

            if (cursor) sorted = sorted.filter((i) => i.cursor < cursor);

            const page = sorted.slice(0, pageSize);
            paginatedItems = page.map((i) => ({ key: i.key, data: i.data }));

            const last = page[page.length - 1];
            nextCursor = last ? last.cursor : null;
            hasMore = page.length === pageSize && sorted.length > pageSize;
        }

        res.status(StatusCodes.OK).send({
            message: ReasonPhrases.OK,
            data: paginatedItems,
            meta: {
                pageSize,
                totalItems,
                nextCursor,
                hasMore,
                source: useDb ? "db" : "memory",
            },
        });
    } catch (error) {
        next(error);
    }
}
router.get("/:index", getAll);

export default router;
