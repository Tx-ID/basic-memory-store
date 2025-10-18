import express from "express";
import { errorHandler } from './middlewares/errorHandler';
import { keyHandler } from "./middlewares/checkKey";

import memoryRoutes from './routes/memory';

const app = express();


//
app.use(express.json());
app.use(keyHandler);


// routes here
app.use("/", memoryRoutes);


//
app.use(errorHandler);
export default app;
