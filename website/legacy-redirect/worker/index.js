const website = 'https://xn--8ovp9s.xn--m8txu.com/phonebridge/';

export default {
  fetch(request) {
    const source = new URL(request.url);
    const target = new URL(website);
    // Assign the path, rather than resolving user input as an absolute URL.
    target.pathname += source.pathname.replace(/^\/+/, '');
    target.search = source.search;
    return new Response(null, {
      status: 301,
      headers: {
        Location: target.href,
        'Cache-Control': 'public, max-age=300',
      },
    });
  },
};
