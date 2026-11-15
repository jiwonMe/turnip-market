export function parseProducts(raw: string): Record<string, number> {
  const value: unknown = JSON.parse(raw);
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length === 0) {
    throw new Error('POLAR_PRODUCT_CREDITS must be a nonempty product-ID to credits mapping');
  }
  for (const [id, credits] of Object.entries(value)) {
    if (!id || !Number.isInteger(credits) || (credits as number) <= 0 || (credits as number) > 2147483647) {
      throw new Error('Invalid Polar product credit mapping');
    }
  }
  return value as Record<string, number>;
}
export function accountId(externalId: unknown): string {
  if (typeof externalId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(externalId)) {
    throw new Error('Missing or invalid external customer ID');
  }
  return externalId;
}
export function productCredits(products: Record<string, number>, id: string | null): number {
  if (!id || !Object.hasOwn(products, id)) throw new Error('Unmapped Polar product');
  return products[id];
}
