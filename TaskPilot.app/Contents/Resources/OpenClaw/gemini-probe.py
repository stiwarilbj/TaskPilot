#!/usr/bin/env python3
"""Pick a responding Gemini model without exposing the API key in arguments."""

import json
import sys
import urllib.error
import urllib.request


MODELS = (
    "google/gemini-3.5-flash-lite",
    "google/gemini-3.1-flash-lite",
    "google/gemini-2.5-flash-lite",
    "google/gemini-3.8-flash",
    "google/gemini-3.5-flash",
    "google/gemini-3-flash-preview",
    "google/gemini-2.5-flash",
)


def choose_model(key, models=MODELS, opener=urllib.request.urlopen):
    failures = []
    payload = json.dumps({"contents": [{"parts": [{"text": "Reply OK"}]}]}).encode()
    for model in models:
        request = urllib.request.Request(
            "https://generativelanguage.googleapis.com/v1beta/models/"
            + model.removeprefix("google/") + ":generateContent",
            data=payload,
            headers={"Content-Type": "application/json", "x-goog-api-key": key},
            method="POST",
        )
        try:
            with opener(request, timeout=20) as response:
                result = json.load(response)
            candidates = result.get("candidates", [])
            if any(
                part.get("text", "").strip()
                for candidate in candidates
                for part in candidate.get("content", {}).get("parts", [])
            ):
                return model, ""
            failures.append(f"{model.removeprefix('google/')}: empty reply")
        except urllib.error.HTTPError as error:
            if error.code in (400, 401, 403):
                body = error.read().decode("utf-8", errors="replace")
                try:
                    message = json.loads(body).get("error", {}).get("message", "")
                except ValueError:
                    message = ""
                if "api key" in message.lower() or "invalid credential" in message.lower():
                    return None, "Google rejected this API key or its permissions. Check the key in Google AI Studio."
            failures.append(f"{model.removeprefix('google/')}: HTTP {error.code}")
        except urllib.error.URLError:
            return None, "Could not reach Google's Gemini API. Check the internet connection and try again."
        except (OSError, ValueError) as error:
            failures.append(f"{model.removeprefix('google/')}: {type(error).__name__}")
    return None, "No Gemini model answered. " + "; ".join(failures)


if __name__ == "__main__":
    api_key = sys.stdin.readline().strip()
    excluded = set(sys.argv[1:])
    model, detail = choose_model(api_key, tuple(model for model in MODELS if model not in excluded))
    print(model or detail)
    sys.exit(0 if model else 1)
