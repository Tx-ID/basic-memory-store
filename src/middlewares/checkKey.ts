import type { NextFunction, Request, Response } from "express";
import { ReasonPhrases, StatusCodes } from 'http-status-codes';
import mongoose from "mongoose";

import config from "../config/config";
import { ApiKeyModel } from "../models/ApiKey";

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

    // If Database is connected, use it for Auth source of truth
    if (mongoose.connection.readyState === 1) {
        try {
            const apiKeyDoc = await ApiKeyModel.findOne({ key: token, active: true });
            
            if (!apiKeyDoc) {
                 return res.status(StatusCodes.UNAUTHORIZED).send({error: ReasonPhrases.UNAUTHORIZED});
            }

            // Extract index from path: /:index/...
            // req.path always starts with /
            const segments = req.path.split("/");
            // segments[0] is "", segments[1] is the index
            const targetIndex = segments[1];

            // If targetIndex exists (it might be empty if root path /), check permissions
            if (targetIndex) {
                const isUniversal = apiKeyDoc.allowedIndexes.includes("*");
                const isAllowed = apiKeyDoc.allowedIndexes.includes(targetIndex);

                if (!isUniversal && !isAllowed) {
                     return res.status(StatusCodes.FORBIDDEN).send({
                        error: ReasonPhrases.FORBIDDEN, 
                        message: `Key not allowed for index: ${targetIndex}`
                    });
                }
            }
            
            return next();

        } catch (error) {
            console.error("Auth Error:", error);
            return res.status(StatusCodes.INTERNAL_SERVER_ERROR).send({error: ReasonPhrases.INTERNAL_SERVER_ERROR});
        }
    }

    // Fallback if DB is not connected (e.g. init phase or failure)
    if (config.keys.includes(token)) {
        return next();
    }

    return res.status(StatusCodes.UNAUTHORIZED).send({error: ReasonPhrases.UNAUTHORIZED});
};
