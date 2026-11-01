export type Status = "open" | "closed"

export interface Author {
  name: string
  avatar: string | null
}

export interface Comment {
  id: number
  body: string
  author: Author
  replies: Comment[]
}

export interface Settings {
  theme: string
  volume: number
}

export enum Size {
  Small = "s",
  Large = "l",
}

export type WithId<T> = T & { id: string }
