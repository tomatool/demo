import test from 'node:test';
import assert from 'node:assert/strict';
import { formatPrice } from '../src/price.js';

test('formats cents as a price', () => {
  assert.equal(formatPrice(250), '2.50 EUR');
  assert.equal(formatPrice(199), '1.99 EUR');
  assert.equal(formatPrice(5), '0.05 EUR');
  assert.equal(formatPrice('1200'), '12.00 EUR');
});
