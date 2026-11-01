---
title: Markdown Preview Fixture
tags: [test, fixture]
---

# Markdown Preview Fixture

A deliberately broad sample used by `tests/run.lua` and the manual headless
check. It covers every block and inline form the plugin supports.

## Inline

**Bold**, *italic*, ***both***, `inline code`, ~~strikethrough~~ and a
[link](https://example.com/docs?q=markdown&x=1). Autolinks such as
<https://example.com/auto> and <hello@example.com> should stay readable.
An image placeholder: ![Luban logo](docs/logo.png).

Escaped \*stars\* and a line with a hard break  
after two spaces, then a soft
break on the next line.

## Lists

- first bullet
- second bullet
  - nested bullet
  - another nested bullet
- [x] completed task
- [ ] pending task

1. first ordered item
2. second ordered item
3. third ordered item

## Quote

> A quoted paragraph with **strong** text.
> > A nested quote.
>
> A second paragraph in the outer quote.

## Code

```rust
fn main() {
    let greeting = "hello";
    println!("{greeting}");
}
```

```python
def greet(name):
    return f"hello {name}"
```

```json
{
  "enabled": true,
  "count": 3
}
```

    indented code
    stays plain

## Table

| Language | 名称 | Stars |
|:---------|:----:|------:|
| Rust     | 鲁班 |  1000 |
| Lua      | 脚本 |    42 |
| Markdown | 文档 |     7 |

## HTML and rules

<div class="note">
Raw HTML blocks are shown as muted text.
</div>

---

## Front matter

The fixture starts with front matter; it is hidden by default.

Setext heading
==============

Another paragraph after the setext heading.
