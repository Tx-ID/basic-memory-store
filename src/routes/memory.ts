import { Router } from "express";
import type { NextFunction, Request, Response } from "express";
import { StatusCodes, ReasonPhrases } from "http-status-codes";
import * as z from "zod";

import config from "../config/config";
import { TTLCache } from "../utils/cache";


//
const router = Router();
const cache = new TTLCache<string, TTLCache<string, any>>();

function get_index_cache(idx: string) {
    const object = cache.get(idx) ?? new TTLCache<string, any>();
    cache.set(idx, object, 0);
    return object;
}


const Query = z.object({
    page: z.preprocess(
        (a) => parseInt(z.string().parse(a), 10),
        z.number().positive().default(1)
    ),
    pageSize: z.preprocess(
        (a) => parseInt(z.string().parse(a), 10),
        z.number().positive().default(10)
    ),
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
        game.set(key, body.data, body.ttl);
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
        res.status(StatusCodes.OK).send({message: ReasonPhrases.OK, data: server});

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
        const { page, pageSize } = safe_query.data;

        const allItems = [];
        for (const key of game.map().keys()) {
            if (game.has(key)) {
                allItems.push({
                    key,
                    data: game.get(key),
                });
            }
        }

        const totalItems = allItems.length;

        if (totalItems === 0) {
            return res.status(StatusCodes.OK).send({
                message: "No data found",
                data: [],
                page: 1,
                pageSize,
                maxPages: 0,
                totalItems: 0,
            });
        }

        const maxPages = Math.ceil(totalItems / pageSize);

        let safePage = page;
        if (safePage > maxPages) {
            safePage = maxPages;
        }
        if (safePage < 1) {
            safePage = 1;
        }

        const startIndex = (safePage - 1) * pageSize;
        const endIndex = safePage * pageSize;
        const paginatedItems = allItems.slice(startIndex, endIndex);

        res.status(StatusCodes.OK).send({
            message: ReasonPhrases.OK,
            data: paginatedItems,
            page: safePage,
            pageSize,
            maxPages,
            totalItems,
        });

    } catch (error) {
        next(error);
    }
}
router.get("/:index", getAll);


//
export default router;
