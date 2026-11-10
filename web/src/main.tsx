import "katex/dist/katex.min.css";
import "./styles.css";
import { install } from "./render";

const container = document.getElementById("root");
if (container) install(container);
