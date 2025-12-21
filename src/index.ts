import server from "./server";
import config from "./config/config";
import mongoose from "mongoose";
import { ApiKeyModel } from "./models/ApiKey";

process.title = config.processTitle;

async function initializeDatabase() {
    if (mongoose.connection.readyState >= 1) {
        console.log("Database connection already established.");
        return;
    }

    if (config.MONGO_CONNECTION_URL === "") {
        console.log(`Database use is disabled.`)
        return;
    }

    try {
        await mongoose.connect(config.MONGO_CONNECTION_URL);
        console.log("Database connected successfully.");

        // Seed keys from env
        for (const key of config.keys) {
            if (!key) continue;
            const exists = await ApiKeyModel.findOne({ key });
            if (!exists) {
                await ApiKeyModel.create({
                    key,
                    allowedIndexes: ["*"],
                    active: true
                });
                console.log(`Seeded env key: ${key.substring(0, 3)}...`);
            }
        }

    } catch (error) {
        console.error("Database connection failed:", error);
        process.exit(1);
    }
}
await initializeDatabase();

server.listen(config.port, () => {
    console.log(`Server running on port ${config.port}`);
});
