import sqlite3
import duckdb

def jaro_distance(s1, s2):
    if not s1 or not s2:
        return 0.0
    
    l1, l2 = len(s1), len(s2)
    match_window = max(1, max(l1, l2) // 2 - 1)
    
    s1_matches = [False] * l1
    s2_matches = [False] * l2
    
    matches = 0
    for i in range(l1):
        start = max(0, i - match_window)
        end = min(l2, i + match_window + 1)
        for j in range(start, end):
            if not s2_matches[j] and s1[i] == s2[j]:
                s1_matches[i] = True
                s2_matches[j] = True
                matches += 1
                break
                
    if matches == 0:
        return 0.0
        
    k = 0
    transpositions = 0
    for i in range(l1):
        if s1_matches[i]:
            while not s2_matches[k]:
                k += 1
            if s1[i] != s2[k]:
                transpositions += 1
            k += 1
            
    t = transpositions / 2
    return (matches / l1 + matches / l2 + (matches - t) / matches) / 3.0

def jaro_winkler(s1, s2, p=0.1):
    j = jaro_distance(s1, s2)
    prefix_len = 0
    for c1, c2 in zip(s1[:4], s2[:4]):
        if c1 == c2:
            prefix_len += 1
        else:
            break
    return j + prefix_len * p * (1 - j)

def resolve_entity(raw_name, entity_type, con, threshold=0.88):
    if not raw_name or not entity_type:
        return None
        
    raw_name_clean = raw_name.strip()
    if not raw_name_clean:
        return None
        
    # 1. Check exact match in lexicon (case-insensitive)
    query = "SELECT canonical_name FROM entity_lexicon WHERE LOWER(raw_name) = LOWER(?);"
    res = con.execute(query, [raw_name_clean]).fetchall()
    
    if res:
        return res[0][0]
        
    # 2. Fetch distinct canonical names for same type
    lexicon_query = "SELECT DISTINCT canonical_name FROM entity_lexicon WHERE entity_type = ?;"
    existing_canonicals = [r[0] for r in con.execute(lexicon_query, [entity_type]).fetchall()]
    
    best_similarity = 0.0
    best_canonical = raw_name_clean
    
    if existing_canonicals:
        raw_lower = raw_name_clean.lower()
        for canon in existing_canonicals:
            sim = jaro_winkler(raw_lower, canon.lower())
            if sim > best_similarity:
                best_similarity = sim
                best_canonical = canon
                
    resolved_canonical = best_canonical if best_similarity >= threshold else raw_name_clean
    
    # 4. Insert mapping
    insert_query = """
        INSERT OR IGNORE INTO entity_lexicon (raw_name, canonical_name, entity_type)
        VALUES (?, ?, ?);
    """
    con.execute(insert_query, [raw_name_clean, resolved_canonical, entity_type])
    
    return resolved_canonical

def resolve_and_store_entities(uid, entities, con):
    """
    entities is a list of dicts, e.g. [{"raw_name": "...", "entity_type": "..."}]
    or a pandas/polars DataFrame, or dictionary representation.
    """
    if not entities:
        return
        
    # Standardize input to list of dicts
    if isinstance(entities, dict):
        # Could be {"name": [...], "type": [...]} or list of dicts
        if "raw_name" in entities and "entity_type" in entities:
            # zip them
            entities = [{"raw_name": n, "entity_type": t} for n, t in zip(entities["raw_name"], entities["entity_type"])]
        elif "name" in entities and "type" in entities:
            entities = [{"raw_name": n, "entity_type": t} for n, t in zip(entities["name"], entities["type"])]
            
    for ent in entities:
        if isinstance(ent, str):
            raw_name = ent
            entity_type = "Unknown"
        else:
            raw_name = ent.get("raw_name") or ent.get("name")
            entity_type = ent.get("entity_type") or ent.get("type")
        if not raw_name or not entity_type:
            continue
            
        canon = resolve_entity(raw_name, entity_type, con)
        if canon:
            insert_query = """
                INSERT INTO entities (uid, entity_type, raw_name, canonical_name)
                VALUES (?, ?, ?, ?);
            """
            con.execute(insert_query, [uid, entity_type, raw_name, canon])
