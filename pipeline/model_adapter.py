import os
import re
import json
import time
import httpx

def get_config():
    # Load credentials.json
    creds_path = "credentials.json"
    config = {
        "gmail_username": "",
        "gmail_app_password": "",
        "db_path": os.getenv("DATABASE_URL", ""),
        "llm_provider": "openrouter",
        "llm_model": "liquid/lfm-2-24b-a2b",
        "embedding_provider": "openrouter",
        "embedding_model": "nomic-embed-text",
        "openrouter_api_key": "",
        "ollama_host": "http://localhost:11434",
        "openai_api_key": "",
        "gemini_api_key": "",
        "forensic_log_path": "FORENSIC_LOG"
    }
    
    if os.path.exists(creds_path):
        try:
            with open(creds_path, "r") as f:
                creds = json.load(f)
                for k, v in creds.items():
                    # Map both original and lowercase keys
                    config[k.lower()] = v
                    config[k] = v
        except Exception as e:
            print(f"Warning: Failed to load credentials: {e}")
            
    # Load manifest.json
    manifest_path = "manifest.json"
    if os.path.exists(manifest_path):
        try:
            with open(manifest_path, "r") as f:
                manifest = json.load(f)
                models = manifest.get("pipeline_models", {})
                meta = models.get("metadata_extraction", {})
                vect = models.get("vector_embeddings", {})
                
                if meta.get("provider"):
                    config["llm_provider"] = meta["provider"]
                if meta.get("model"):
                    config["llm_model"] = meta["model"]
                if vect.get("provider"):
                    config["embedding_provider"] = vect["provider"]
                if vect.get("model"):
                    config["embedding_model"] = vect["model"]
        except Exception as e:
            print(f"Warning: Failed to load manifest: {e}")
            
    # Environmental overrides
    for k in config.keys():
        env_val = os.getenv(k.upper())
        if env_val:
            config[k] = env_val
            
    return config

def log_forensic_response(provider, model, prompt, system_prompt, response_text, reasoning_content=None, config=None):
    log_path = config.get("forensic_log_path", "FORENSIC_LOG") if config else "FORENSIC_LOG"
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    
    sys_prompt_str = f"SYSTEM PROMPT:\n{system_prompt}\n" if system_prompt else ""
    
    log_entry = (
        "================================================================================\n"
        f"TIMESTAMP: {timestamp}\n"
        f"PROVIDER:  {provider}\n"
        f"MODEL:     {model}\n"
        f"{sys_prompt_str}"
        "------------------------------------ PROMPT ------------------------------------\n"
        f"{prompt}\n"
        "---------------------------------- RESPONSE ------------------------------------\n"
    )
    
    if reasoning_content:
        log_entry += (
            "--- THINKING PROCESS ---\n"
            f"{reasoning_content}\n"
            "--- FINAL ANSWER ---\n"
        )
        
    log_entry += (
        f"{response_text}\n"
        "================================================================================\n\n"
    )
    
    try:
        with open(log_path, "a") as f:
            f.write(log_entry)
    except Exception as e:
        print(f"Warning: Failed to write to FORENSIC_LOG: {e}")

def generate_completion(prompt, system_prompt=None, json_mode=False, config=None):
    if not config:
        config = get_config()
        
    provider = config.get("llm_provider", "openrouter").lower()
    model = config.get("llm_model", "liquid/lfm-2-24b-a2b")
    
    messages = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    messages.append({"role": "user", "content": prompt})
    
    max_retries = 3
    attempt = 1
    
    while attempt <= max_retries:
        content = None
        reasoning = None
        err_msg = None
        
        try:
            with httpx.Client(timeout=60.0) as client:
                if provider == "openrouter":
                    api_key = config.get("openrouter_api_key")
                    if not api_key:
                        raise ValueError("openrouter_api_key is not configured.")
                        
                    headers = {
                        "Authorization": f"Bearer {api_key}",
                        "HTTP-Referer": "https://github.com/Arf9999/newsletter_phase2",
                        "X-Title": "Push Media Pipeline"
                    }
                    body = {
                        "model": model,
                        "messages": messages,
                        "max_tokens": 4000
                    }
                    if json_mode:
                        body["response_format"] = {"type": "json_object"}
                        
                    resp = client.post("https://openrouter.ai/api/v1/chat/completions", json=body, headers=headers)
                    if resp.status_code != 200:
                        raise Exception(f"OpenRouter error: {resp.text}")
                        
                    res_json = resp.json()
                    choice_msg = res_json["choices"][0]["message"]
                    content = choice_msg.get("content")
                    reasoning = choice_msg.get("reasoning_content") or choice_msg.get("reasoning")
                    
                elif provider == "ollama":
                    url = f"{config.get('ollama_host', 'http://localhost:11434')}/api/chat"
                    body = {
                        "model": model,
                        "messages": messages,
                        "stream": False
                    }
                    if json_mode:
                        body["format"] = "json"
                        
                    resp = client.post(url, json=body)
                    if resp.status_code != 200:
                        raise Exception(f"Ollama error: {resp.text}")
                        
                    res_json = resp.json()
                    content = res_json["message"]["content"]
                    
                elif provider == "openai":
                    api_key = config.get("openai_api_key") or config.get("openrouter_api_key")
                    if not api_key:
                        raise ValueError("openai_api_key is not configured.")
                        
                    headers = {"Authorization": f"Bearer {api_key}"}
                    body = {
                        "model": model,
                        "messages": messages
                    }
                    if json_mode:
                        body["response_format"] = {"type": "json_object"}
                        
                    resp = client.post("https://api.openai.com/v1/chat/completions", json=body, headers=headers)
                    if resp.status_code != 200:
                        raise Exception(f"OpenAI error: {resp.text}")
                        
                    res_json = resp.json()
                    choice_msg = res_json["choices"][0]["message"]
                    content = choice_msg.get("content")
                    reasoning = choice_msg.get("reasoning_content")
                    
                else:
                    raise ValueError(f"Unknown LLM provider: {provider}")
                    
        except Exception as e:
            err_msg = str(e)
            
        if err_msg:
            print(f"LLM API call failed on attempt {attempt}: {err_msg}")
            attempt += 1
            if attempt <= max_retries:
                time.sleep(1)
            continue
            
        if content:
            # Check for recurring characters (e.g. repeated words/symbols)
            # Match R regex: grepl("(.{3,})\\1{8,}", content, perl = TRUE)
            has_repeats = bool(re.search(r'(.{3,})\1{8,}', content))
            json_invalid = False
            
            if json_mode:
                try:
                    json.loads(content)
                except Exception:
                    json_invalid = True
                    
            if has_repeats or json_invalid:
                reason = "recurring characters detected" if has_repeats else "malformed JSON/truncated"
                print(f"LLM output rejected ({reason}) on attempt {attempt}. Retrying...")
                
                log_forensic_response(
                    provider=f"{provider}-rejected-{reason}",
                    model=model,
                    prompt=prompt,
                    system_prompt=system_prompt,
                    response_text=content,
                    reasoning_content=reasoning,
                    config=config
                )
                attempt += 1
                if attempt <= max_retries:
                    time.sleep(1)
            else:
                log_forensic_response(
                    provider=provider,
                    model=model,
                    prompt=prompt,
                    system_prompt=system_prompt,
                    response_text=content,
                    reasoning_content=reasoning,
                    config=config
                )
                return content
        else:
            print(f"Empty response on attempt {attempt}. Retrying...")
            attempt += 1
            if attempt <= max_retries:
                time.sleep(1)
                
    raise Exception(f"Failed to obtain a valid completion after {max_retries} attempts.")

def generate_embeddings(text, config=None):
    if not config:
        config = get_config()
        
    provider = config.get("embedding_provider", "openrouter").lower()
    model = config.get("embedding_model", "nomic-embed-text")
    
    if not text or not text.strip():
        return None
        
    with httpx.Client(timeout=30.0) as client:
        if provider == "openrouter":
            api_key = config.get("openrouter_api_key")
            if not api_key:
                raise ValueError("OPENROUTER_API_KEY is not configured for embeddings.")

            headers = {"Authorization": f"Bearer {api_key}"}
            body = {
                "model": model,
                "input": text
            }
            resp = client.post("https://openrouter.ai/api/v1/embeddings", json=body, headers=headers)
            if resp.status_code != 200:
                raise Exception(f"Embeddings error: {resp.text}")
            res_json = resp.json()
            return res_json["data"][0]["embedding"]

        elif provider == "openai":
            api_key = config.get("openai_api_key")
            if not api_key:
                raise ValueError("OPENAI_API_KEY is not configured for embeddings.")
                
            headers = {"Authorization": f"Bearer {api_key}"}
            body = {
                "model": model,
                "input": text
            }
            resp = client.post("https://api.openai.com/v1/embeddings", json=body, headers=headers)
            if resp.status_code != 200:
                raise Exception(f"Embeddings error: {resp.text}")
            res_json = resp.json()
            return res_json["data"][0]["embedding"]
            
        elif provider == "ollama":
            url = f"{config.get('ollama_host', 'http://localhost:11434')}/api/embed"
            body = {
                "model": model,
                "input": text
            }
            resp = client.post(url, json=body)
            if resp.status_code != 200:
                raise Exception(f"Ollama error: {resp.text}")
            res_json = resp.json()
            return res_json["embeddings"][0]
            
        else:
            raise ValueError(f"Unknown embedding provider: {provider}")
