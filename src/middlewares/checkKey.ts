import type { NextFunction, Request, Response } from "express";
import { ReasonPhrases, StatusCodes } from 'http-status-codes';

import config from "../config/config";

export const keyHandler = (
    req: Request,
    res: Response,
    next: NextFunction,
) => {
    if (config.keys.some(key => req.headers.authorization === `Bearer ${key}`)) {
        return next();
    }
    return res.status(StatusCodes.UNAUTHORIZED).send({error: ReasonPhrases.UNAUTHORIZED});
};
