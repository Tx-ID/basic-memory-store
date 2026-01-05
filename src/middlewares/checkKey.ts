import type { NextFunction, Request, Response } from "express";
import { ReasonPhrases, StatusCodes } from 'http-status-codes';
import mongoose from "mongoose";

import config from "../config/config";
import { ApiKeyModel } from "../models/ApiKey";

// Simple in-memory cache for API keys
const authCache = new Map<string, { allowedIndexes: string[], expiry: number }>();
const CACHE_TTL = 60 * 1000; // 1 minute

export const keyHandler = async (
    req: Request,
    res: Response,
    next: NextFunction,
) => {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
         return res.status(StatusCodes.UNAUTHORIZED).send({error: ReasonPhrases.UNAUTHORIZED});
    }

    const token = authHeader.split(" ")[1];
    if (!token) {
        return res.status(StatusCodes.UNAUTHORIZED).send({error: ReasonPhrases.UNAUTHORIZED});
    }

    // Check Cache first
    const cached = authCache.get(token);
    if (cached && cached.expiry > Date.now()) {
        res.locals.allowedIndexes = cached.allowedIndexes;
    } else {
        // If Database is connected, use it for Auth source of truth
        if (mongoose.connection.readyState === 1) {
            try {
                const apiKeyDoc = await ApiKeyModel.findOne({ key: token, active: true }).lean();
                
                if (!apiKeyDoc) {
                     return res.status(StatusCodes.UNAUTHORIZED).send({error: ReasonPhrases.UNAUTHORIZED});
                }

                // Cache the result
                authCache.set(token, {
                    allowedIndexes: apiKeyDoc.allowedIndexes,
                    expiry: Date.now() + CACHE_TTL
                });

                res.locals.allowedIndexes = apiKeyDoc.allowedIndexes;
            } catch (error) {
                console.error("Auth Error:", error);
                return res.status(StatusCodes.INTERNAL_SERVER_ERROR).send({error: ReasonPhrases.INTERNAL_SERVER_ERROR});
            }
        } else {
            // Fallback if DB is not connected (e.g. init phase or failure)
            if (config.keys.includes(token)) {
                res.locals.allowedIndexes = ["*"];
            } else {
                return res.status(StatusCodes.UNAUTHORIZED).send({error: ReasonPhrases.UNAUTHORIZED});
            }
        }
    }

    // Permissions check logic (using res.locals.allowedIndexes)
    const allowedIndexes = res.locals.allowedIndexes;
    const isUniversal = allowedIndexes.includes("*");

    // Special case: Global Batch endpoint checks permissions per-item in the handler
    if (req.path === "/batch/set" || req.path === "/batch/buffered") {
        return next();
    }

    // Extract index from path: /:index/...
    const segments = req.path.split("/");
    const targetIndex = segments[1];

    if (targetIndex && !["batch", "sorted", "rank"].includes(targetIndex)) {
        const isAllowed = allowedIndexes.includes(targetIndex);

        if (!isUniversal && !isAllowed) {
             return res.status(StatusCodes.FORBIDDEN).send({
                error: ReasonPhrases.FORBIDDEN, 
                message: `Key not allowed for index: ${targetIndex}`
            });
        }
    }
    
    return next();
};
