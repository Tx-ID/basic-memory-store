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

        const list = [];
        for (const key of game.map().keys()) {
            if (game.has(key)) {
                list.push({
                    key,
                    data: game.get(key),
                });
            }
        }
        res.status(StatusCodes.OK).send({message: ReasonPhrases.OK, data: list});

    } catch (error) {
        next(error);
    }
}
router.get("/:index", getAll);


//
export default router;
