import { Router } from "express";
import type { NextFunction, Request, Response } from "express";
import { ReasonPhrases, StatusCodes } from "http-status-codes";
import * as z from "zod";
import mongoose from "mongoose";

import config from "../config/config";
import { TTLCache } from "../utils/cache";
import { CacheModel } from "../models/MemoryCache";

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

const SortedQuery = z.object({
    pageSize: z.coerce.number().int().positive().max(5000).default(5000),
    cursor: z.string().optional(),
    sortDirection: z.enum(["asc", "desc"]).default("desc"),
    dataName: z.string(),
    useDb: z.coerce.boolean().default(false),
    defaultValue: z.string().optional(),
});

const Body = z.object({
    ttl: z.number().int().default(2 * 60),
    data: z.any(),
    persist: z.boolean().default(false), // Toggle DB Write
});

const isDbReady = () => mongoose.connection.readyState === 1;

// Helper to handle mixed type comparison
function compare(a: any, b: any, dir: "asc" | "desc") {
    if (a === b) return 0;
    if (dir === "asc") return a > b ? 1 : -1;
    return a < b ? 1 : -1;
}

// Helper to parse cursor/value
function parseValue(val: string | undefined): string | number | undefined {
    if (val === undefined) return undefined;
    const num = Number(val);
    return isNaN(num) ? val : num;
}


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

async function getSorted(req: Request, res: Response, next: NextFunction) {
    try {
        const index = String(req.params.index!);
        const safe = SortedQuery.safeParse(req.query);
        if (!safe.success) {
            return res.status(StatusCodes.BAD_REQUEST).send({
                error: ReasonPhrases.BAD_REQUEST,
                error_data: safe.error.issues,
            });
        }

        const { pageSize, cursor, sortDirection, dataName, useDb, defaultValue } = safe.data;
        const parsedCursor = parseValue(cursor);
        const parsedDefaultValue = parseValue(defaultValue);

        let paginatedItems: any[] = [];
        let nextCursor: string | number | null = null;
        let hasMore = false;
        let totalItems = 0;

        if (useDb) {
            if (!isDbReady()) {
                return res.status(StatusCodes.SERVICE_UNAVAILABLE).send({ 
                    error: ReasonPhrases.SERVICE_UNAVAILABLE, 
                    message: "Database not connected" 
                });
            }

            const sortOrder = sortDirection === "asc" ? 1 : -1;
            const filterOp = sortDirection === "asc" ? "$gt" : "$lt";

            if (parsedDefaultValue !== undefined) {
                // Use Aggregation to handle default value
                const pipeline: any[] = [
                    { $match: { index } },
                    {
                        $addFields: {
                            sortVal: { $ifNull: [`$payload.${dataName}`, parsedDefaultValue] }
                        }
                    }
                ];

                if (parsedCursor !== undefined) {
                    pipeline.push({ $match: { sortVal: { [filterOp]: parsedCursor } } });
                }

                pipeline.push({ $sort: { sortVal: sortOrder } });
                pipeline.push({ $limit: pageSize });

                const docs = await CacheModel.aggregate(pipeline).exec();

                // For total items, we technically should count everything in index
                totalItems = await CacheModel.countDocuments({ index });

                paginatedItems = docs.map((d) => ({ key: d.key, data: d.payload }));

                if (docs.length > 0) {
                    const last = docs[docs.length - 1];
                    nextCursor = last.sortVal;

                    // Check hasMore
                    const checkPipeline: any[] = [
                        { $match: { index } },
                        {
                            $addFields: {
                                sortVal: { $ifNull: [`$payload.${dataName}`, parsedDefaultValue] }
                            }
                        },
                        { $match: { sortVal: { [filterOp]: nextCursor } } },
                        { $limit: 1 },
                        { $project: { _id: 1 } }
                    ];
                    const rem = await CacheModel.aggregate(checkPipeline).exec();
                    hasMore = rem.length > 0;
                }

            } else {
                // Standard Find
                const q: any = { index };
                if (parsedCursor !== undefined) {
                    q[`payload.${dataName}`] = { [filterOp]: parsedCursor };
                }
                // Filter out missing fields if no default value provided
                q[`payload.${dataName}`] = { $exists: true, ...q[`payload.${dataName}`] };

                const docs = await CacheModel.find(q)
                    .sort({ [`payload.${dataName}`]: sortOrder })
                    .limit(pageSize)
                    .lean();

                totalItems = await CacheModel.countDocuments({ index, [`payload.${dataName}`]: { $exists: true } });

                paginatedItems = docs.map((d) => ({ key: d.key, data: d.payload }));

                if (docs.length > 0) {
                    const last = docs[docs.length - 1]!;
                    nextCursor = last.payload[dataName];
                    
                    const checkQ = { ...q };
                    if (nextCursor !== undefined) {
                        checkQ[`payload.${dataName}`] = { [filterOp]: nextCursor, $exists: true };
                    }
                    const rem = await CacheModel.findOne(checkQ).select("_id");
                    hasMore = !!rem;
                }
            }
        } else {
            const game = get_index_cache(index);
            const allEntries = [];

            for (const key of game.map().keys()) {
                const entry = game.get(key);
                if (entry && entry.payload) {
                    const val = entry.payload[dataName] ?? parsedDefaultValue;
                    if (val !== undefined) {
                         allEntries.push({
                            key,
                            data: entry.payload,
                            val: val,
                        });
                    }
                }
            }

            allEntries.sort((a, b) => compare(a.val, b.val, sortDirection));
            totalItems = allEntries.length;

            let filtered = allEntries;
            if (parsedCursor !== undefined) {
                filtered = allEntries.filter(i => {
                    if (sortDirection === "asc") return i.val > parsedCursor;
                    return i.val < parsedCursor;
                });
            }

            const page = filtered.slice(0, pageSize);
            paginatedItems = page.map((i) => ({ key: i.key, data: i.data }));

            const last = page[page.length - 1];
            nextCursor = last ? last.val : null;
            hasMore = page.length === pageSize && filtered.length > pageSize;
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
router.get("/:index/sorted", getSorted);

async function getRank(req: Request, res: Response, next: NextFunction) {
    try {
        const index = String(req.params.index!);
        const key = String(req.params.id!);
        
        const safe = SortedQuery.safeParse(req.query);
        if (!safe.success) {
            return res.status(StatusCodes.BAD_REQUEST).send({
                error: ReasonPhrases.BAD_REQUEST,
                error_data: safe.error.issues,
            });
        }
        const { sortDirection, dataName, useDb, defaultValue } = safe.data;
        const parsedDefaultValue = parseValue(defaultValue);

        let rank = 0;

        if (useDb) {
            if (!isDbReady()) {
                return res.status(StatusCodes.SERVICE_UNAVAILABLE).send({ 
                    error: ReasonPhrases.SERVICE_UNAVAILABLE, 
                    message: "Database not connected" 
                });
            }

            const doc = await CacheModel.findOne({ index, key }).lean();
            if (!doc) {
                return res.status(StatusCodes.NOT_FOUND).send({ error: ReasonPhrases.NOT_FOUND });
            }

            const targetVal = doc.payload[dataName] ?? parsedDefaultValue;
            if (targetVal === undefined) {
                return res.status(StatusCodes.BAD_REQUEST).send({ error: "Field not found in data and no default provided" });
            }

            const filterOp = sortDirection === "asc" ? "$lt" : "$gt";
            
            if (parsedDefaultValue !== undefined) {
                const pipeline = [
                    { $match: { index } },
                    {
                        $addFields: {
                            sortVal: { $ifNull: [`$payload.${dataName}`, parsedDefaultValue] }
                        }
                    },
                    { $match: { sortVal: { [filterOp]: targetVal } } },
                    { $count: "count" }
                ];
                const result = await CacheModel.aggregate(pipeline).exec();
                rank = (result[0]?.count || 0) + 1;
            } else {
                const count = await CacheModel.countDocuments({
                    index,
                    [`payload.${dataName}`]: { [filterOp]: targetVal, $exists: true }
                });
                rank = count + 1;
            }

        } else {
            const game = get_index_cache(index);
            const entry = game.get(key);
            if (!entry) {
                return res.status(StatusCodes.NOT_FOUND).send({ error: ReasonPhrases.NOT_FOUND });
            }

            const targetVal = entry.payload[dataName] ?? parsedDefaultValue;
            if (targetVal === undefined) {
                return res.status(StatusCodes.BAD_REQUEST).send({ error: "Field not found in data and no default provided" });
            }

            let betterCount = 0;
            for (const k of game.map().keys()) {
                const item = game.get(k);
                if (item && item.payload) {
                    const val = item.payload[dataName] ?? parsedDefaultValue;
                    if (val !== undefined) {
                        if (sortDirection === "asc") {
                            if (val < targetVal) betterCount++;
                        } else {
                            if (val > targetVal) betterCount++;
                        }
                    }
                }
            }
            rank = betterCount + 1;
        }

        res.status(StatusCodes.OK).send({
            message: ReasonPhrases.OK,
            data: { rank },
        });

    } catch (error) {
        next(error);
    }
}
router.get("/:index/rank/:id", getRank);

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
