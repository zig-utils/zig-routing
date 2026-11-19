import { expect, test } from 'bun:test'
import { loadOutline, parseOutline } from './lib'

function row(key: string, blockers: string): string {
  return `${key} | Example | infra | infra | S | ${blockers}`
}

test('accepts a later blocker without changing issue priority', () => {
  const source = [row('P0.01', 'P1.01'), row('P1.01', '-')].join('\n')
  expect(parseOutline(source).issues.map(issue => issue.key)).toEqual(['P0.01', 'P1.01'])
  expect(loadOutline().issues.length).toBeGreaterThan(0)
})

test('rejects missing blockers and dependency cycles', () => {
  expect(() => parseOutline(row('P0.01', 'P1.01'))).toThrow('unknown issue P1.01')
  const source = [row('P0.01', 'P1.01'), row('P1.01', 'P0.01')].join('\n')
  expect(() => parseOutline(source)).toThrow('P0.01 -> P1.01 -> P0.01')
})
