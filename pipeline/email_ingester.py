import re
import email
from email.header import decode_header
import datetime
from imapclient import IMAPClient
from html.parser import HTMLParser

class EmailHTMLParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.text_parts = []
        self.current_link = None
        self.browser_url = None
        self.in_ignored_tag = False

    def handle_starttag(self, tag, attrs):
        if tag in ('style', 'script', 'head', 'title', 'meta'):
            self.in_ignored_tag = True
        elif tag == 'a':
            self.current_link = dict(attrs).get('href', None)

    def handle_endtag(self, tag):
        if tag in ('style', 'script', 'head', 'title', 'meta'):
            self.in_ignored_tag = False
        elif tag == 'a':
            self.current_link = None

    def handle_data(self, data):
        if self.in_ignored_tag:
            return
        cleaned_data = data.strip()
        if cleaned_data:
            self.text_parts.append(cleaned_data)
            if self.current_link:
                lower_text = cleaned_data.lower()
                patterns = [
                    "view in browser", "view online", "read online", "read in browser",
                    "view this email in your browser", "view this post in your browser",
                    "open in browser", "view on web", "read on the web", "read on substack",
                    "read on ghost", "view on substack"
                ]
                if any(pat in lower_text for pat in patterns):
                    self.browser_url = self.current_link

    def get_text(self):
        return " ".join(self.text_parts)

def clean_html_to_text(html_content):
    parser = EmailHTMLParser()
    try:
        parser.feed(html_content)
        text = parser.get_text()
        
        # CRITICAL FIX: Strip invisible formatting unicode characters (zero-width joiners, etc.)
        # Marketing emails (like News24) often repeat these characters 50+ times to hide preview text.
        # This causes non-transformer State-Space Models (like Liquid LFM) to hit recursive collapse states
        # and endlessly repeat tokens, leading to malformed JSON and timeouts.
        text = re.sub(r'[\u200b\u200c\u200d\uFEFF\u200e\u200f]+', ' ', text)
        
        return text, parser.browser_url
    except Exception:
        return html_content, None

def decode_mime_words(s):
    if not s:
        return ""
    try:
        decoded_parts = decode_header(s)
        result = []
        for part, encoding in decoded_parts:
            if isinstance(part, bytes):
                result.append(part.decode(encoding or 'utf-8', errors='replace'))
            else:
                result.append(part)
        return "".join(result)
    except Exception:
        return s

def parse_email_datetime(date_str):
    if not date_str:
        return datetime.datetime.utcnow()
    formats = [
        "%a, %d %b %Y %H:%M:%S %z",
        "%a, %d %b %Y %H:%M:%S",
        "%a %d %b %Y %H:%M:%S %z",
        "%d %b %Y %H:%M:%S %z",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%dT%H:%M:%S%z"
    ]
    for fmt in formats:
        try:
            cleaned_date = re.sub(r'\s*\([^)]+\)$', '', date_str.strip())
            dt = datetime.datetime.strptime(cleaned_date, fmt)
            if dt.tzinfo:
                dt = dt.astimezone(datetime.timezone.utc).replace(tzinfo=None)
            return dt
        except ValueError:
            continue
    return datetime.datetime.utcnow()

_gmail_client_instance = None

def get_gmail_client(username, password):
    """
    Singleton connection manager for Gmail IMAP.
    """
    global _gmail_client_instance
    if _gmail_client_instance is not None:
        try:
            _gmail_client_instance.noop()
            return _gmail_client_instance
        except Exception:
            try:
                _gmail_client_instance.logout()
            except Exception:
                pass
            _gmail_client_instance = None

    print("Opening a new persistent Gmail IMAP connection...")
    client = IMAPClient('imap.gmail.com', use_uid=True, ssl=True, timeout=30)
    client.login(username, password)
    client.select_folder('INBOX')
    _gmail_client_instance = client
    return client

def close_gmail_client():
    global _gmail_client_instance
    if _gmail_client_instance is not None:
        try:
            print("Logging out persistent Gmail IMAP connection...")
            _gmail_client_instance.logout()
        except Exception:
            pass
        _gmail_client_instance = None

def fetch_email_metadata_and_text(client, uids):
    """
    Fetches email headers and selective body content in a single bulk roundtrip
    to prevent Gmail IMAP command rate limit throttling.
    """
    if not uids:
        return {}

    # Single bulk fetch roundtrip
    fetch_keys = ['ENVELOPE', 'BODY[TEXT]', 'RFC822.HEADER']
    res = client.fetch(uids, fetch_keys)
    
    records = {}
    
    for uid, data in res.items():
        try:
            envelope = data.get(b'ENVELOPE')
            header_bytes = data.get(b'RFC822.HEADER') or b""
            body_bytes = data.get(b'BODY[TEXT]') or b""
            
            subject = ""
            from_sender = ""
            date_str = ""
            
            if envelope:
                subject = decode_mime_words(envelope.subject.decode('utf-8', errors='replace') if envelope.subject else "")
                
                from_parts = []
                if envelope.from_:
                    for addr in envelope.from_:
                        name = decode_mime_words(addr.name.decode('utf-8', errors='replace') if addr.name else "")
                        mailbox = addr.mailbox.decode('utf-8', errors='replace') if addr.mailbox else ""
                        host = addr.host.decode('utf-8', errors='replace') if addr.host else ""
                        email_addr = f"{mailbox}@{host}"
                        if name:
                            from_parts.append(f"{name} <{email_addr}>")
                        else:
                            from_parts.append(email_addr)
                from_sender = ", ".join(from_parts) if from_parts else "Unknown Sender"
                
                if envelope.date:
                    date_str = envelope.date.decode('utf-8', errors='replace') if isinstance(envelope.date, bytes) else str(envelope.date)
            else:
                msg = email.message_from_bytes(header_bytes)
                subject = decode_mime_words(msg['subject'])
                from_sender = decode_mime_words(msg['from'])
                date_str = msg['date']

            # Parse MIME body bytes locally using Python email package
            body_text = ""
            browser_url = None
            
            if body_bytes:
                # Reconstruct full MIME part to let email package parse boundaries
                mime_msg = email.message_from_bytes(header_bytes + b"\n\n" + body_bytes)
                
                # Walk parts to find text/plain or text/html
                plain_part = None
                html_part = None
                
                for part in mime_msg.walk():
                    content_type = part.get_content_type()
                    disposition = part.get_content_disposition()
                    
                    # Skip attachments
                    if disposition == 'attachment':
                        continue
                        
                    if content_type == 'text/plain':
                        plain_part = part
                    elif content_type == 'text/html':
                        html_part = part
                
                # Extract content (HTML preferred to parse browser URL)
                target_part = html_part if html_part else plain_part
                if target_part:
                    try:
                        payload = target_part.get_payload(decode=True)
                        charset = target_part.get_content_charset() or 'utf-8'
                        decoded_payload = payload.decode(charset, errors='replace')
                        
                        if target_part == html_part:
                            body_text, browser_url = clean_html_to_text(decoded_payload)
                        else:
                            body_text = decoded_payload
                    except Exception:
                        pass
                else:
                    # Fallback to direct decoding of body_bytes
                    try:
                        body_text = body_bytes.decode('utf-8', errors='replace')
                    except Exception:
                        body_text = body_bytes.decode('latin1', errors='replace')

            pub_name = "Email Intake"
            email_match = re.search(r'<([^>]+)>', from_sender)
            sender_email = email_match.group(1) if email_match else from_sender
            
            name_part = re.sub(r'<[^>]+>', '', from_sender).strip()
            name_part = name_part.strip('\'"')
            if name_part:
                pub_name = name_part
            elif '@' in sender_email:
                pub_name = sender_email.split('@')[1]

            records[uid] = {
                "uid": str(uid),
                "datetime": parse_email_datetime(date_str),
                "source": pub_name,
                "sender": sender_email,
                "title": subject,
                "url": browser_url,
                "body": body_text.strip(),
                "raw_email": (header_bytes + b"\n\n" + body_bytes).decode('utf-8', errors='replace')
            }
        except Exception as e:
            import traceback
            print(f"Error parsing message UID {uid}: {e}")
            traceback.print_exc()
            
    return records
