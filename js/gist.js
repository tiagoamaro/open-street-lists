/**
 * GitHub Gist API wrapper.
 * All methods throw on non-2xx responses so callers can catch and surface errors.
 */
const Gist = (() => {
  const BASE = 'https://api.github.com';

  function headers(token) {
    return {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'Content-Type': 'application/json',
    };
  }

  async function assertOk(res) {
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      throw new Error(body.message || `HTTP ${res.status}`);
    }
    return res;
  }

  /**
   * Loads lists.json from an existing Gist.
   * @param {string} gistId
   * @param {string} token
   * @returns {Promise<{version: number, lists: Array}>}
   */
  async function load(gistId, token) {
    const res = await fetch(`${BASE}/gists/${gistId}`, { headers: headers(token) });
    await assertOk(res);
    const data = await res.json();
    const content = data.files['lists.json']?.content;
    if (!content) throw new Error('lists.json not found in this Gist.');
    return JSON.parse(content);
  }

  /**
   * Updates lists.json in an existing Gist.
   * @param {string} gistId
   * @param {string} token
   * @param {{version: number, lists: Array}} data
   */
  async function save(gistId, token, data) {
    const res = await fetch(`${BASE}/gists/${gistId}`, {
      method: 'PATCH',
      headers: headers(token),
      body: JSON.stringify({
        files: { 'lists.json': { content: JSON.stringify(data, null, 2) } },
      }),
    });
    await assertOk(res);
  }

  /**
   * Creates a new secret Gist with lists.json and returns its ID.
   * @param {string} token
   * @param {{version: number, lists: Array}} data
   * @returns {Promise<string>} gist ID
   */
  async function create(token, data) {
    const res = await fetch(`${BASE}/gists`, {
      method: 'POST',
      headers: headers(token),
      body: JSON.stringify({
        description: 'Open Street Lists — favorite places data',
        public: false,
        files: { 'lists.json': { content: JSON.stringify(data, null, 2) } },
      }),
    });
    await assertOk(res);
    const result = await res.json();
    return result.id;
  }

  return { load, save, create };
})();
