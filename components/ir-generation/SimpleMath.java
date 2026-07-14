public final class SimpleMath {
    private SimpleMath() {
    }

    public static int sumOfSquares(int limit) {
        int sum = 0;
        for (int i = 1; i <= limit; i++) {
            sum += i * i;
        }
        return sum;
    }

    public static int fibonacci(int n) {
        if (n < 2) {
            return n;
        }
        return fibonacci(n - 1) + fibonacci(n - 2);
    }

    public static void main(String[] args) {
        int limit = args.length == 0 ? 10 : Integer.parseInt(args[0]);
        System.out.println("sumOfSquares(" + limit + ") = " + sumOfSquares(limit));
        System.out.println("fibonacci(10) = " + fibonacci(10));
    }
}
