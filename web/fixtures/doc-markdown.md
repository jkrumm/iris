# Release notes

A short document with **bold**, _italic_, ~~strikethrough~~, `inline code` and a [link to the docs](https://example.com/docs).

## Checklist

- [x] Write the spec
- [ ] Review the draft
- [ ] Ship it

## Results

| Step                                                            | Median | Share |
| --------------------------------------------------------------- | -----: | ----: |
| Transcribe                                                      |  2.4 s |   18% |
| Act                                                             |  8.1 s |   61% |
| A very long step name that has to wrap inside the narrow column |  1.2 s |    9% |

> The island never scrolls inside. Wide content wraps.

```ts
export const total = (xs: number[]): number => xs.reduce((a, b) => a + b, 0);
```

```python
def fib(n: int) -> int:
    return n if n < 2 else fib(n - 1) + fib(n - 2)
```

```bash
for f in *.m4a; do ffmpeg -i "$f" "${f%.m4a}.mp3"; done
```

Inline math $E = mc^2$ and a block:

$$
\int_0^1 x^2\,dx = \frac{1}{3}
$$

![A blue banner](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADAAAAAYCAIAAAAzn+mLAAAAOUlEQVR4nGNwLlk2qBDDgLtg1EGjITSahkZz2UAXPKPl0GgIjaah0Vw20AXPaDk0GkKjaciZvrkMAD+VItvzFqTNAAAAAElFTkSuQmCC)

![Remote picture](https://example.com/picture.png)
