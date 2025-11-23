import { Router } from "express";
import type { NextFunction, Request, Response } from "express";
import { StatusCodes, ReasonPhrases } from "http-status-codes";
import * as z from "zod";

import config from "../config/config";
import { TTLCache } from "../utils/cache";


//
const router = Router();
const cache = new TTLCache<string, TTLCache<string, {payload: any, cursor: number}>>();

function get_index_cache(idx: string) {
    let object = cache.get(idx);
    if (!object) {
        object = new TTLCache();
        cache.set(idx, object, 0);
    }
    return object;
}


const Query = z.object({
    pageSize: z.coerce.number()
        .int()
        .positive()
        .max(5000)
        .default(5000),
    cursor: z.coerce.number().optional(),
});

//
const Body = z.object({
    ttl: z.int().default(2 * 60),
    data: z.any(),
});
type Body = z.infer<typeof Body>;

async function set(req: Request, res: Response, next: NextFunction) {
    try {
        const index = String(req.params.index!);
        const game = get_index_cache(index);

        const key = String(req.params.id!);

        const safe_body = Body.safeParse(req.body);
        if (!safe_body.success) {
            return res.status(StatusCodes.BAD_REQUEST).send({error: ReasonPhrases.BAD_REQUEST, error_data: safe_body.error.issues})
        }

        const body = safe_body.data;

        const cursor = Date.now(); 
        const cacheEntry = {
            payload: body.data,
            cursor: cursor
        };

        game.set(key, cacheEntry, body.ttl);
        res.status(StatusCodes.OK).send({message: ReasonPhrases.OK});

    } catch (error) {
        next(error);
    }
}
router.post("/:index/:id", set);

async function del(req: Request, res: Response, next: NextFunction) {
    try {
        const index = String(req.params.index!);
        const game = get_index_cache(index);

        const key = String(req.params.id!);

        game.delete(key);
        res.status(StatusCodes.OK).send({message: ReasonPhrases.OK});

    } catch (error) {
        next(error);
    }
}
router.delete("/:index/:id", del);

async function get(req: Request, res: Response, next: NextFunction) {
    try {
        const index = String(req.params.index!);
        const key = String(req.params.id!);

        const game = get_index_cache(index);
        const server = game.get(key);
        res.status(StatusCodes.OK).send({message: ReasonPhrases.OK, data: server?.payload});

    } catch (error) {
        next(error);
    }
}
router.get("/:index/:id", get);

async function getAll(req: Request, res: Response, next: NextFunction) {
    try {
        const index = String(req.params.index!);
        const game = get_index_cache(index);

        const safe_query = Query.safeParse(req.query);
        if (!safe_query.success) {
            return res.status(StatusCodes.BAD_REQUEST).send({error: ReasonPhrases.BAD_REQUEST, error_data: safe_query.error.issues})
        }
        const { cursor, pageSize } = safe_query.data;

        const allEntries = [];
        for (const key of game.map().keys()) {
            const entry = game.get(key);
            if (entry) {
                allEntries.push({
                    key: key,
                    data: entry.payload,
                    cursor: entry.cursor,
                });
            }
        }

        let sortedItems = allEntries.sort((a, b) => b.cursor - a.cursor);
        const totalItems = sortedItems.length;

        if (cursor) {
            sortedItems = sortedItems.filter(item => item.cursor < cursor);
        }

        const rawPageItems = sortedItems.slice(0, pageSize);

        const lastItem = rawPageItems[rawPageItems.length - 1];
        const nextCursor = lastItem ? lastItem.cursor : null;

        const paginatedItems = rawPageItems.map(item => ({
            key: item.key,
            data: item.data
        }));

        const hasMore = paginatedItems.length === pageSize && sortedItems.length > pageSize;

        res.status(StatusCodes.OK).send({
            message: ReasonPhrases.OK,
            data: paginatedItems,
            meta: {
                pageSize,
                totalItems,
                nextCursor, 
                hasMore,
            },
        });

    } catch (error) {
        next(error);
    }
}
router.get("/:index", getAll);


//
export default router;
