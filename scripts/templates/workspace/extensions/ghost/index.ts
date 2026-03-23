import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const helperPath = path.join(__dirname, "ghost.py");

const GHOST_ACTIONS = ["inspect", "list_posts", "get_post", "create_draft", "update_draft"] as const;
const POST_STATUSES = ["all", "draft", "published", "scheduled", "sent"] as const;

type ToolArgs = {
  action: typeof GHOST_ACTIONS[number];
  site?: string;
  status?: typeof POST_STATUSES[number];
  limit?: number;
  page?: number;
  post_id?: string;
  slug?: string;
  title?: string;
  html?: string;
  lexical?: string;
  excerpt?: string;
  meta_title?: string;
  meta_description?: string;
  canonical_url?: string;
  tags?: string[];
};

function runGhost(args: ToolArgs) {
  const stdout = execFileSync("python3", [helperPath], {
    env: process.env,
    maxBuffer: 2 * 1024 * 1024,
    input: JSON.stringify(args),
    encoding: "utf-8",
  });
  return JSON.parse(stdout || "{}");
}

function formatStatus(status: string | undefined) {
  return status || "unknown";
}

function summarize(result: any) {
  if (!result || typeof result !== "object") {
    return "Ghost tool completed.";
  }
  if (result.error) {
    return `Ghost tool failed: ${result.error}`;
  }
  if (result.action === "inspect") {
    const sites = Array.isArray(result.configuredSites) ? result.configuredSites : [];
    const lines = sites.map((item: any) => {
      if (item.reachable) {
        return `${item.site}: configured, enabled, and reachable${item.title ? ` (${item.title})` : ""}`;
      }
      return `${item.site}: configured but unreachable${item.error ? ` (${item.error})` : ""}`;
    });
    return `Ghost integration is ${result.enabled ? "enabled" : "disabled"} and ${result.configured ? "configured" : "missing configuration"}.${
      lines.length ? `\n${lines.join("\n")}` : ""
    }`;
  }
  if (Array.isArray(result.posts)) {
    if (!result.posts.length) {
      return `Found 0 posts for ${result.site || "the selected site"}.`;
    }
    const lines = result.posts.slice(0, 10).map((post: any) => {
      const tags = Array.isArray(post.tags) && post.tags.length ? ` | tags: ${post.tags.slice(0, 3).join(", ")}` : "";
      return `${post.id} | ${post.title || "(untitled)"} | ${formatStatus(post.status)} | ${post.slug || "no-slug"}${tags}`;
    });
    return `Found ${result.posts.length} post${result.posts.length === 1 ? "" : "s"} for ${result.site}:\n${lines.join("\n")}`;
  }
  if (result.post) {
    const post = result.post;
    return `${result.action === "create_draft" ? "Created" : result.action === "update_draft" ? "Updated" : "Fetched"} Ghost post ${post.id}: ${
      post.title || "(untitled)"
    }\nStatus: ${formatStatus(post.status)}\nSlug: ${post.slug || "none"}\nUpdated: ${post.updated_at || "unknown"}`;
  }
  return "Ghost tool completed.";
}

export default function register(api: any) {
  api.registerTool(
    {
      name: "ghost",
      description:
        "Inspect Ghost CMS setup, fetch existing posts, and create or update drafts only. This tool cannot publish.",
      parameters: {
        type: "object",
        additionalProperties: false,
        required: ["action"],
        properties: {
          action: {
            type: "string",
            enum: [...GHOST_ACTIONS],
            description: "The Ghost operation to perform.",
          },
          site: {
            type: "string",
            description: "Configured site alias such as `wonderful` or `asima`.",
          },
          status: {
            type: "string",
            enum: [...POST_STATUSES],
            description: "Optional status filter for list_posts. Defaults to `all`.",
          },
          limit: {
            type: "integer",
            minimum: 1,
            maximum: 50,
            description: "Maximum number of posts to return for list_posts.",
          },
          page: {
            type: "integer",
            minimum: 1,
            maximum: 100,
            description: "Pagination page for list_posts.",
          },
          post_id: {
            type: "string",
            description: "Ghost post ID for get_post or update_draft.",
          },
          slug: {
            type: "string",
            description: "Optional post slug for get_post, create_draft, or update_draft.",
          },
          title: {
            type: "string",
            description: "Draft title for create_draft or update_draft.",
          },
          html: {
            type: "string",
            description: "HTML content for create_draft or update_draft. Do not pass with `lexical`.",
          },
          lexical: {
            type: "string",
            description: "Lexical JSON string for create_draft or update_draft. Do not pass with `html`.",
          },
          excerpt: {
            type: "string",
            description: "Custom excerpt for create_draft or update_draft.",
          },
          meta_title: {
            type: "string",
            description: "SEO meta title for create_draft or update_draft.",
          },
          meta_description: {
            type: "string",
            description: "SEO meta description for create_draft or update_draft.",
          },
          canonical_url: {
            type: "string",
            description: "Optional canonical URL for create_draft or update_draft.",
          },
          tags: {
            type: "array",
            items: {
              type: "string",
            },
            description: "List of Ghost tag names to attach to the draft.",
          },
        },
      },
      execute(_callId: string, args: ToolArgs) {
        const result = runGhost(args);
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
