import dotenv from "dotenv";

dotenv.config({
    quiet: true
});

interface Config {
    port: number;
    nodeEnv: string;
    keys: string[];
    MONGO_CONNECTION_URL: string,
    processTitle: string;
}

//
const keys: string[] = [];
(process.env.KEYS || "").split(",").forEach(str => keys.push(str));


//
const config: Config = {
    port: Number(process.env.PORT) || 3000,
    nodeEnv: process.env.NODE_ENV || "development",
    keys,
    MONGO_CONNECTION_URL: process.env.MONGO_CONNECTION_URL ?? "",
    processTitle: process.env.PROCESS_TITLE || "basic-memory-store",
};

export default config;
