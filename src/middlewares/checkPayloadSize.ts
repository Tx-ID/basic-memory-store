import { Request, Response, NextFunction } from 'express';
import util from 'util';

export function checkPayloadSize(req: Request, res: Response, next: NextFunction) {
    const contentLength = req.headers['content-length'];
    if (contentLength) {
        const size = parseInt(contentLength, 10);
        if (!isNaN(size) && size > 1024 * 1024) { // 1MB
            console.warn(`[WARNING] Request payload size (${(size / (1024 * 1024)).toFixed(2)} MB) to ${req.method} ${req.originalUrl} exceeds 1MB warning threshold.`);
            
            if (req.body && Object.keys(req.body).length > 0) {
                 const preview = util.inspect(req.body, { depth: 1, maxArrayLength: 5, colors: false });
                 console.warn(`[PAYLOAD PREVIEW] for ${req.method} ${req.originalUrl}: ${preview.substring(0, 2000)}...`);
            } else {
                console.warn(`[PAYLOAD PREVIEW] for ${req.method} ${req.originalUrl}: Body is empty or not parsed (Content-Type: ${req.headers['content-type']}).`);
            }
        }
    }
    next();
}
