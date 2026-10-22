import { createSupabaseContext } from "npm:@supabase/server@1";
import { handleCorsPreflightRequest, jsonResponse } from "../_shared/cors.ts";

const OPENAI_EMBEDDINGS_URL = "https://api.openai.com/v1/embeddings";
const EMBEDDING_MODEL = "text-embedding-3-small";
const EMBEDDING_DIMENSIONS = 512;
const MAX_QUESTION_LENGTH = 8_000;

Deno.serve(async (request: Request): Promise<Response> => {
  if (request.method === "OPTIONS") {
    return handleCorsPreflightRequest();
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, {
      status: 405,
      headers: { Allow: "POST, OPTIONS" },
    });
  }

  // The gateway JWT check is disabled for this function to support the new
  // publishable-key setup. Validate the user's Supabase session here instead.
  const { error: authError } = await createSupabaseContext(request, {
    auth: "user",
  });
  if (authError) {
    return jsonResponse({ error: "You must be signed in to use semantic search." }, {
      status: authError.status || 401,
    });
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: "Request body must be valid JSON." }, { status: 400 });
  }

  const question = (body as { question?: unknown } | null)?.question;
  if (typeof question !== "string" || question.trim().length === 0) {
    return jsonResponse({ error: 'A non-empty "question" string is required.' }, {
      status: 400,
    });
  }

  const normalizedQuestion = question.trim();
  if (normalizedQuestion.length > MAX_QUESTION_LENGTH) {
    return jsonResponse({
      error: `Question must be ${MAX_QUESTION_LENGTH} characters or fewer.`,
    }, { status: 413 });
  }

  const openAiApiKey = Deno.env.get("OPENAI_API_KEY");
  if (!openAiApiKey) {
    console.error("OPENAI_API_KEY is not configured for this function.");
    return jsonResponse({ error: "Embedding service is not configured." }, { status: 500 });
  }

  let openAiResponse: Response;
  try {
    openAiResponse = await fetch(OPENAI_EMBEDDINGS_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${openAiApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: EMBEDDING_MODEL,
        input: normalizedQuestion,
        dimensions: EMBEDDING_DIMENSIONS,
      }),
    });
  } catch (error) {
    console.error("Could not reach the OpenAI embeddings API:", error);
    return jsonResponse({ error: "Could not reach the embedding service." }, { status: 502 });
  }

  if (!openAiResponse.ok) {
    console.error("OpenAI embeddings request failed with status:", openAiResponse.status);
    return jsonResponse({ error: "The embedding service could not process the question." }, {
      status: 502,
    });
  }

  try {
    const result = await openAiResponse.json();
    const embedding = result?.data?.[0]?.embedding;
    if (!Array.isArray(embedding) || embedding.length !== EMBEDDING_DIMENSIONS) {
      console.error("OpenAI returned an unexpected embeddings response.");
      return jsonResponse({ error: "The embedding service returned an invalid response." }, {
        status: 502,
      });
    }

    return jsonResponse({ embedding });
  } catch (error) {
    console.error("Could not read the OpenAI embeddings response:", error);
    return jsonResponse({ error: "The embedding service returned an invalid response." }, {
      status: 502,
    });
  }
});
