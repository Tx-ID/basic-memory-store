import mongoose, { Schema } from "mongoose";
import type { Document } from "mongoose";

export interface ICacheDoc extends Document {
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

export const CacheModel = mongoose.model<ICacheDoc>("DynamicCache", CacheSchema);
