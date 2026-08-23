import re

with open('lib/views/components/header_bar.dart', 'r') as f:
    content = f.read()

# We will replace the entire file content, but preserving the imports and class declaration structure
