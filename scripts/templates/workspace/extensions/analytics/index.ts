import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const helperPath = path.join(__dirname, "status.py");

const ANALYTICS_ACTIONS = [
  "inspect",
  "landing_pages",
  "organic_trends",
  "content_engagement",
  "conversion_summary",
] as const;

type ToolArgs = {
  action: typeof ANALYTICS_ACTIONS[number];
  site?: string;
  days?: number;
  limit?: number;
  url?: string;
};

function runAnalytics(args: ToolArgs) {
  const stdout = execFileSync("python3", [helperPath], {
    env: process.env,
    maxBuffer: 2 * 1024 * 1024,
    input: JSON.stringify(args),
    encoding: "utf-8",
  });
  return JSON.parse(stdout || "{}");
}

function formatNumber(value: number | undefined) {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 }).format(value || 0);
}

function formatPercent(value: number | undefined) {
  return `${(((value || 0) as number) * 100).toFixed(1)}%`;
}

function formatDuration(seconds: number | undefined) {
  const total = Math.round(Number(seconds) || 0);
  const minutes = Math.floor(total / 60);
  const remainder = total % 60;
  if (minutes <= 0) {
    return `${remainder}s`;
  }
  return `${minutes}m ${String(remainder).padStart(2, "0")}s`;
}

function shortenPath(value: string | undefined) {
  if (!value) return "/";
  if (value.length <= 72) return value;
  return `${value.slice(0, 69)}...`;
}

function summarize(result: any) {
  if (!result || typeof result !== "object") {
    return "Analytics tool completed.";
  }
  if (result.error) {
    return `Analytics tool failed: ${result.error}`;
  }
  if (result.action === "inspect") {
    const configuredSites = Array.isArray(result.configuredSites) ? result.configuredSites : [];
    const lines = configuredSites.map((item: any) => {
      const status = item.accessible ? "accessible" : item.error ? `unreachable (${item.error})` : "not checked";
      return `${item.site}: property ${item.propertyId || "missing"} (${status})`;
    });
    return `Analytics integration is ${result.enabled ? "enabled" : "disabled"} and ${result.configured ? "configured" : "missing configuration"}.${
      lines.length ? `\n${lines.join("\n")}` : ""
    }`;
  }
  if (Array.isArray(result.landingPages)) {
    if (!result.landingPages.length) {
      return `No landing page data found for ${result.site || "the selected site"} in ${result.dateWindow?.days || "the selected"} days.`;
    }
    const lines = result.landingPages.slice(0, 10).map((item: any) => {
      return `${shortenPath(item.landingPage)} | ${formatNumber(item.sessions)} sessions | ${formatDuration(item.averageSessionDuration)} avg engagement | ${formatPercent(item.sessionKeyEventRate)} key-event rate`;
    });
    return `Top landing pages for ${result.site} over ${result.dateWindow?.days || "?"} days:\n${lines.join("\n")}`;
  }
  if (Array.isArray(result.trend)) {
    const sessions = result.summary?.sessions;
    const keyEvents = result.summary?.keyEvents;
    return `Organic trends for ${result.site} over ${result.dateWindow?.days || "?"} days:\nSessions ${formatNumber(
      sessions?.current,
    )} (${sessions?.deltaPct == null ? "n/a" : formatPercent(sessions.deltaPct)})\nKey events ${formatNumber(
      keyEvents?.current,
    )} (${keyEvents?.deltaPct == null ? "n/a" : formatPercent(keyEvents.deltaPct)})`;
  }
  if (result.action === "content_engagement") {
    const summary = result.summary || {};
    if (result.landingPage) {
      const topChannels = Array.isArray(result.channelBreakdown) ? result.channelBreakdown.slice(0, 3) : [];
      const channelsText = topChannels.length
        ? `\nTop channels: ${topChannels.map((item: any) => `${item.sessionDefaultChannelGroup || "Unknown"} (${formatNumber(item.sessions)} sessions)`).join(", ")}`
        : "";
      return `Content engagement for ${shortenPath(result.landingPage)} on ${result.site}:\n${formatNumber(
        summary.sessions,
      )} sessions | ${formatDuration(summary.averageSessionDuration)} avg engagement | ${formatPercent(
        summary.engagementRate,
      )} engagement | ${formatNumber(summary.keyEvents)} key events${channelsText}`;
    }
    const topEngaged = Array.isArray(result.topEngagedPages) ? result.topEngagedPages.slice(0, 3) : [];
    const lowEngaged = Array.isArray(result.lowEngagementPages) ? result.lowEngagementPages.slice(0, 2) : [];
    return `Content engagement snapshot for ${result.site}:\n${formatNumber(summary.sessions)} sessions | ${formatDuration(
      summary.averageSessionDuration,
    )} avg engagement\nTop engaged: ${topEngaged.map((item: any) => shortenPath(item.landingPage)).join(", ") || "none"}\nWatchlist: ${
      lowEngaged.map((item: any) => shortenPath(item.landingPage)).join(", ") || "none"
    }`;
  }
  if (Array.isArray(result.channels) || Array.isArray(result.landingPages)) {
    const keyEvents = result.summary?.keyEvents;
    return `Conversion summary for ${result.site} over ${result.dateWindow?.days || "?"} days:\nKey events ${formatNumber(
      keyEvents?.current,
    )} (${keyEvents?.deltaPct == null ? "n/a" : formatPercent(keyEvents.deltaPct)})\nOrganic key events ${formatNumber(
      result.organicSummary?.keyEvents,
    )}`;
  }
  return "Analytics tool completed.";
}

export default function register(api: any) {
  api.registerTool(
    {
      name: "analytics",
      description:
        "Inspect Google Analytics setup and retrieve landing-page, organic trend, engagement, and conversion data for configured sites.",
      parameters: {
        type: "object",
        additionalProperties: false,
        required: ["action"],
        properties: {
          action: {
            type: "string",
            enum: [...ANALYTICS_ACTIONS],
            description: "The Analytics operation to perform.",
          },
          site: {
            type: "string",
            description: "Configured site alias such as `wonderful` or `asima`.",
          },
          days: {
            type: "integer",
            minimum: 1,
            maximum: 365,
            description: "Number of days to look back for the selected analytics report.",
          },
          limit: {
            type: "integer",
            minimum: 1,
            maximum: 50,
            description: "Maximum number of landing pages or rows to return.",
          },
          url: {
            type: "string",
            description: "Optional full URL or path for content_engagement.",
          },
        },
      },
      execute(_callId: string, args: ToolArgs) {
        const result = runAnalytics(args);
        return {
          content: [
            {
              type: "text",
              text: summarize(result),
            },
          ],
          structuredContent: result,
        };
      },
    },
    { optional: true },
  );
}
