import express from "express";
import { errorHandler } from './middlewares/errorHandler';
import { keyHandler } from "./middlewares/checkKey";
import { checkPayloadSize } from "./middlewares/checkPayloadSize";

import memoryRoutes from './routes/memory';

const app = express();


// Authentication first (Fastest check)
app.use(keyHandler);

// Then payload checks and parsing
app.use(express.json({ limit: "50mb" }));
app.use(express.urlencoded({ limit: "50mb", extended: true }));
app.use(checkPayloadSize);


// routes here
app.use("/", memoryRoutes);


//
app.use(errorHandler);
export default app;
