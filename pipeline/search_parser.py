import re

class SearchParserError(Exception):
    pass

class Node:
    def to_sql(self, space="english"):
        raise NotImplementedError()
    def get_params(self, space="english"):
        return []

class TermNode(Node):
    def __init__(self, term):
        self.term = term

    def to_sql(self, space="english"):
        # Translate wildcards
        sql_term = self.term.replace('*', '%').replace('?', '_')
        # If it doesn't already have wildcards, we wrap it in % to match anywhere
        if '%' not in sql_term and '_' not in sql_term:
            sql_term = f"%{sql_term}%"
        
        col = "summary" if space == "english" else "original_language_summary"
        return f"((title ILIKE ?) OR ({col} ILIKE ?))"
    
    def get_params(self, space="english"):
        sql_term = self.term.replace('*', '%').replace('?', '_')
        if not sql_term.startswith('%'):
            sql_term = '%' + sql_term
        if not sql_term.endswith('%'):
            sql_term = sql_term + '%'
        return [sql_term, sql_term]

class PhraseNode(Node):
    def __init__(self, phrase):
        self.phrase = phrase
        
    def to_sql(self, space="english"):
        col = "summary" if space == "english" else "original_language_summary"
        return f"((title ILIKE ?) OR ({col} ILIKE ?))"

    def get_params(self, space="english"):
        return [f"%{self.phrase}%", f"%{self.phrase}%"]

class NearNode(Node):
    def __init__(self, term1, term2, distance):
        self.term1 = term1
        self.term2 = term2
        self.distance = distance
        
    def to_sql(self, space="english"):
        col = "summary" if space == "english" else "original_language_summary"
        return f"REGEXP_MATCHES({col}, ?, 'i')"
        
    def get_params(self, space="english"):
        # word1(?:\W+\w+){0,distance}\W+word2 OR reversed
        w1 = re.escape(self.term1.replace('*', '').replace('?', ''))
        w2 = re.escape(self.term2.replace('*', '').replace('?', ''))
        pattern = f"{w1}(?:\\W+\\w+){{0,{self.distance}}}\\W+{w2}|{w2}(?:\\W+\\w+){{0,{self.distance}}}\\W+{w1}"
        return [pattern]

class AndNode(Node):
    def __init__(self, left, right):
        self.left = left
        self.right = right
        
    def to_sql(self, space="english"):
        return f"({self.left.to_sql(space)} AND {self.right.to_sql(space)})"

    def get_params(self, space="english"):
        return self.left.get_params(space) + self.right.get_params(space)

class OrNode(Node):
    def __init__(self, left, right):
        self.left = left
        self.right = right
        
    def to_sql(self, space="english"):
        return f"({self.left.to_sql(space)} OR {self.right.to_sql(space)})"
        
    def get_params(self, space="english"):
        return self.left.get_params(space) + self.right.get_params(space)

class NotNode(Node):
    def __init__(self, child):
        self.child = child
        
    def to_sql(self, space="english"):
        return f"(NOT {self.child.to_sql(space)})"
        
    def get_params(self, space="english"):
        return self.child.get_params(space)

# Tokenizer
def tokenize(query):
    # Regex to match tokens: quotes, parens, or words
    token_pattern = r'(?i)(\"[^\"]*\")|(\()|(\))|(NEAR/\d+)|(AND|OR|NOT)|([^\s\(\)\"]+)'
    matches = re.finditer(token_pattern, query)
    tokens = []
    for match in matches:
        token = match.group(0)
        if token.startswith('"') and token.endswith('"'):
            tokens.append(('PHRASE', token[1:-1]))
        elif token == '(':
            tokens.append(('LPAREN', token))
        elif token == ')':
            tokens.append(('RPAREN', token))
        elif token.upper().startswith('NEAR/'):
            tokens.append(('NEAR', int(token.upper().split('/')[1])))
        elif token.upper() in ('AND', 'OR', 'NOT'):
            tokens.append(('OP', token.upper()))
        else:
            tokens.append(('TERM', token))
    return tokens

# Parser
class Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.pos = 0

    def current(self):
        if self.pos < len(self.tokens):
            return self.tokens[self.pos]
        return None

    def advance(self):
        self.pos += 1

    def match(self, expected_type, expected_val=None):
        tok = self.current()
        if tok and tok[0] == expected_type:
            if expected_val is None or tok[1] == expected_val:
                self.advance()
                return True
        return False

    def parse(self):
        if not self.tokens:
            return None
        node = self.parse_or()
        if self.current() is not None:
            raise SearchParserError("Unexpected token at end of query")
        return node

    def parse_or(self):
        node = self.parse_and()
        while self.match('OP', 'OR'):
            right = self.parse_and()
            node = OrNode(node, right)
        return node

    def parse_and(self):
        node = self.parse_not()
        # Implicit AND for adjacent terms, or explicit AND
        while True:
            is_explicit_and = self.match('OP', 'AND')
            
            # Lookahead to see if next is a valid term/group/NOT
            next_tok = self.current()
            if not next_tok:
                if is_explicit_and:
                    raise SearchParserError("Trailing AND")
                break
                
            if next_tok[0] in ('TERM', 'PHRASE', 'LPAREN') or (next_tok[0] == 'OP' and next_tok[1] == 'NOT'):
                right = self.parse_not()
                node = AndNode(node, right)
            else:
                if is_explicit_and:
                    raise SearchParserError("Expected term after AND")
                break
        return node

    def parse_not(self):
        if self.match('OP', 'NOT'):
            child = self.parse_primary()
            return NotNode(child)
        return self.parse_primary()

    def parse_primary(self):
        tok = self.current()
        if not tok:
            raise SearchParserError("Unexpected end of query")
            
        if tok[0] == 'LPAREN':
            self.advance()
            node = self.parse_or()
            if not self.match('RPAREN'):
                raise SearchParserError("Missing closing parenthesis")
            return node
            
        if tok[0] == 'TERM':
            self.advance()
            # Check for NEAR
            next_tok = self.current()
            if next_tok and next_tok[0] == 'NEAR':
                dist = next_tok[1]
                self.advance()
                right_tok = self.current()
                if not right_tok or right_tok[0] not in ('TERM', 'PHRASE'):
                    raise SearchParserError("Expected term after NEAR")
                right_term = right_tok[1]
                self.advance()
                return NearNode(tok[1], right_term, dist)
            return TermNode(tok[1])
            
        if tok[0] == 'PHRASE':
            self.advance()
            return PhraseNode(tok[1])
            
        raise SearchParserError(f"Unexpected token: {tok[1]}")

def build_sql_from_query(query_string, space="english"):
    if not query_string or not query_string.strip():
        return "1=1", []
    tokens = tokenize(query_string)
    parser = Parser(tokens)
    try:
        ast = parser.parse()
        if ast:
            return ast.to_sql(space), ast.get_params(space)
    except SearchParserError as e:
        # Fallback to basic term matching if parsing fails
        pass
    
    # Fallback: Treat as a single phrase search
    ast = PhraseNode(query_string)
    return ast.to_sql(space), ast.get_params(space)
