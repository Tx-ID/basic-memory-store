import mongoose, { Schema } from "mongoose";
import type { Document } from "mongoose";

export interface IApiKey extends Document {
    key: string;
    allowedIndexes: string[];
    active: boolean;
}

const ApiKeySchema = new Schema<IApiKey>({
    key: { type: String, required: true, unique: true, index: true },
    allowedIndexes: { type: [String], default: ["*"] }, // "*" means access to all indexes
    active: { type: Boolean, default: true },
});

export const ApiKeyModel = mongoose.model<IApiKey>("ApiKey", ApiKeySchema);
