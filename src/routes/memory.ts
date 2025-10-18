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
        const server = get_index_cache(index);

        const key = String(req.params.id!);

        const safe_body = Body.safeParse(req.body);
        if (!safe_body.success) {
            return res.status(StatusCodes.BAD_REQUEST).send({error: ReasonPhrases.BAD_REQUEST, error_data: safe_body.error.issues})
        }

        const body = safe_body.data;
        server.set(key, body.data, body.ttl);
        res.status(StatusCodes.OK).send({message: ReasonPhrases.OK});

    } catch (error) {
        next(error);
    }
}
router.post("/:index/:id", set);

async function getAll(req: Request, res: Response, next: NextFunction) {
    try {
        const index = String(req.params.index!);
        const server = get_index_cache(index);

        const list = [];
        for (const key of server.map().keys()) {
            if (server.has(key)) {
                list.push({
                    key,
                    data: server.get(key),
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
